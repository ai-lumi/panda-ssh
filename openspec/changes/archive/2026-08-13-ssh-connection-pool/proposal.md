# SSH Connection Pool

## Why

当前 Panda SSH 的每一次 SFTP/终端操作都新建一条 TCP + SSH 连接，导致目录导航、批量传输、终端与 SFTP 并发时重复握手与认证，延迟高、服务器压力大。通过引入连接池实现会话复用，可显著降低操作延迟并减轻服务器端连接负载。

## What Changes

- 在 `panda-core` 新增连接池模块，以 `(host_id, credentials)` 为键缓存 `SshSession`
- 池内连接空闲超过 30 秒自动关闭回收
- 复用同一 `SshSession` 的多路频道能力：终端 shell、SFTP、远程命令执行共享同一连接
- 所有现有 FFI 调用（`test_connection`、`sftp_list`、`sftp_upload`、`sftp_download`、`shell_open`、`shell_read`、`shell_write`）通过连接池获取会话，外部 API 不变
- 连接池内部自动处理连接失效后的重连与故障转移

## Capabilities

### New Capabilities
- `connection-pool`: 连接生命周期管理与复用策略

### Modified Capabilities
- `ssh-connection`: 增加"连接复用"语义；原"建立会话"需求扩展为"优先从池中获取已有会话，无可用会话时新建"

## Impact

- `crates/panda-core`: 新增连接池模块，修改 `SshSession` 连接入口
- `crates/panda-ffi`: 所有 FFI 函数通过连接池获取会话，不再直接调用 `SshSession::connect`
- `apple/PandaSSH`: 无 Swift 侧改动；行为不变，性能提升
- 对 macOS 与 iPadOS 双端影响一致（纯 Rust 核心层改动）

## Non-goals

- 不实现跨主机的连接共享（池按键隔离）
- 不改变 Swift 侧的 API 或调用方式
- 本期不做连接数上限的动态流控（保持简单 LRU + 超时）
