# SSH Connection Pool Design

## Context

当前 `panda-ffi` 中的每一个 FFI 调用（`sftp_list`、`sftp_upload`、`shell_open`、`test_connection` 等）都独立调用 `SshSession::connect()`，完成一次完整的 TCP 三次握手 + SSH 密钥交换 + 认证。对于目录浏览、批量传输、终端与 SFTP 并发等场景，这造成了严重的重复开销。

Rust 核心使用 `russh` 库，`SshSession` 内部持有一条 TCP 连接，支持在同一连接上打开多个频道（channel）。russh-sftp 的 `SftpClient` 基于一个频道构建。连接池需要复用 `SshSession` 的 TCP 连接，同时允许多个并发的 SFTP 会话和 shell 频道。

现有 `panda-core` 中的 `SshSession` 已具备 `disconnect()` 方法，支持优雅关闭。

## Goals / Non-Goals

**Goals:**
- 对同一 `(host_id, credentials)` 的多次操作复用同一条 TCP + SSH 连接
- 空闲会话 30 秒后自动回收，避免长连接占用资源
- 复用前检测会话活性，断开会话自动剔除并重建
- 支持单连接多路并发：终端 shell + SFTP + exec 共享同一条连接
- 连接池操作线程安全，兼容 tokio 多任务环境
- 所有现有 FFI 函数零改动（内部透明走连接池）

**Non-Goals:**
- 不做连接数上限的动态流控（保持简单超时回收）
- 不做跨主机的连接共享
- 不改变 Swift 侧 API
- 本期不做连接预热或预建立

## Decisions

### 决策 1：以 `Arc<tokio::sync::Mutex<HashMap<PoolKey, PoolEntry>>>` 实现全局单例池

**选择：** 使用 `OnceLock` + `tokio::sync::Mutex` 维护全局连接池。

**理由：**
- `tokio::sync::Mutex` 允许在 async 上下文中安全地持有锁跨越 await 点，不会阻塞 worker 线程
- `OnceLock` 保证懒初始化且无重复创建
- 全局单例与现有 FFI 全局状态（`STORES`、`TRANSFER_TASKS`）风格一致

**替代方案：** 将连接池注入每个调用点。拒绝原因：会改变大量 FFI 函数的签名和调用链，与“外部 API 不变”的目标冲突。

### 决策 2：`PoolKey` 包含 `host_id` + 密码/口令哈希，避免不同凭据复用同一会话

**选择：** `PoolKey` 由 `host_id` 和凭据内容（密码或密钥路径+口令）的派生标识组成。

**理由：** 同一主机使用不同密码（如用户改密后重试）时，必须不能复用旧会话的认证上下文。凭据变化 = 新会话。

**实现：** 对凭据做 `to_string()` 后取 hash，不存储明文。

### 决策 3：池条目持有 `Arc<SshSession>`，计数引用；取出时通过 `open_channel()` 打开新频道

**选择：** 池中存 `Arc<SshSession>`，获取时调用 `session.open_channel()` 创建独立频道。

**理由：**
- `russh` 的 `SshSession` 内部已做多路复用，多个频道共享同一 TCP 连接
- `Arc` 保证只要池内或任何使用者仍持有 `SshSession`，连接就不会被 `Drop` 关闭
- 回收时只需从池中移除条目；当所有 `Arc` 引用归零，`SshSession` 自动断开

### 决策 4：空闲超时通过定期检查任务（tokio task）实现

**选择：** 启动一个后台 tokio task，每 5 秒扫描池内条目，关闭超时会话。

**理由：**
- 简单可靠，不依赖 `Drop` 或弱引用时机
- 5 秒检查粒度足够，开销可忽略

**替代方案：** 使用 `tokio::time::timeout` 包裹每次获取操作。拒绝原因：获取操作的超时与空闲超时语义不同，混在一起会导致误杀活跃连接。

### 决策 5：会话活性检测在获取时进行（惰性检测）

**选择：** 从池中取出条目后，不立即 ping 检测，而是直接尝试 `open_channel()`；若失败则判定为失效并重建。

**理由：**
- 避免无意义的网络往返（ping）
- `open_channel()` 本身就是最可靠的活性测试
- 失败路径走原有 `SshSession::connect()` 重建逻辑，代码复用

### 决策 6：新文件 `crates/panda-core/src/connection_pool.rs`，不改动 `ssh.rs` 的公开接口

**选择：** 新增独立模块，在 `SshSession` 外封装一层 `get_or_create_session()`。

**理由：**
- `ssh.rs` 保持职责单一（SSH 协议实现）
- 连接池逻辑独立可测
- 不影响 `ssh.rs` 的现有单元测试

## Risks / Trade-offs

- **[Risk] 连接池中的 `Arc<SshSession>` 可能长时间不释放，导致服务器端连接堆积**
  → **缓解：** 空闲超时 + 强制回收；超时后从池中移除，仅当其他频道仍活跃时 `Arc` 计数不为零，此时连接是合理活跃的
- **[Risk] 多路并发下某频道错误可能导致整连接断开**
  → **缓解：** russh 的 channel 错误隔离性良好，单频道错误不会波及同连接的其他频道；若底层 TCP 断开，则所有频道同时失效，这是协议层面预期行为
- **[Risk] 连接池全局锁在高并发场景成为瓶颈**
  → **缓解：** 锁仅保护 HashMap 的读写，不涉及网络 I/O；每次获取/归还操作是 O(1)；若未来成为瓶颈，可拆分为 per-key shard
- **[Risk] 密码哈希作为 key 可能暴露凭据信息（通过 side channel）**
  → **缓解：** 使用 `std::collections::hash_map::DefaultHasher` 对凭据字符串做哈希，仅存储 u64 哈希值，不存明文；side channel 风险极低

## Migration Plan

1. 新增 `panda-core/src/connection_pool.rs` 及单元测试
2. 修改 `panda-ffi/src/lib.rs` 中的 `connect_host`（或新增 `get_or_create_session` 封装），让 `open_sftp_session`、`test_connection`、`shell_open` 等函数走连接池
3. 运行 `cargo test` 全绿后，`build-rust.sh` → `xcodebuild` 验证
4. 无 Swift 侧改动，无需迁移

## Open Questions

- 空闲超时时间是否需暴露为配置项？本期保持硬编码 30 秒，后续根据用户反馈调整。
- 连接池是否需要容量上限？本期不设上限，仅依赖空闲超时自然回收。
