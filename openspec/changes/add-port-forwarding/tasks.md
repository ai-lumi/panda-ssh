# 任务：SSH 端口转发（Port Forwarding）

## 依赖前置（Phase 0）

> Phase 0 全部是 spike 和验证，不写正式业务代码。通过后才能进入 Phase 1。

### Phase 0-S1：russh direct-tcpip API spike

- [ ] **Spike**：用 russh 0.62 写 PoC 脚本 `examples/spike_direct_tcpip.rs`——建立 SSH 连接 → 调用 `channel_open_direct_tcpip("localhost", 80)` → 确认 Channel 返回且能收发数据
- [ ] **验证**：Channel 是否实现了 AsyncRead + AsyncWrite（或需要手动实现）
- [ ] **验证**：返回值类型、错误类型、是否需要先握手确认

### Phase 0-S2：russh tcpip-forward API spike

- [ ] **Spike**：用 russh 0.62 写 PoC——SSH 连接 → 请求 `tcpip-forward(127.0.0.1, 9090)` → 确认服务端接受 → 等待远端连接回调
- [ ] **验证**：回调机制是 Stream 还是 Channel 事件
- [ ] **验证**：服务端接受后返回什么类型、如何接收被转发的连接

### Phase 0-S3：本地 TCP listener ↔ direct-tcpip 桥接 PoC

- [ ] **Spike**：本地 TcpListener accept → 打开 direct-tcpip → `tokio::io::copy_bidirectional` 双向拷贝
- [ ] **验证**：背压行为正常、任一端断开后另一端正确清理

### Phase 0-验收

- [ ] 三个 Spike 全部成功运行并记录结果
- [ ] 记录 russh 0.62 所需的具体 API 签名
- [ ] 如果任何 Spike 失败，决定升级 russh 版本或调整方案

---

## Phase 1：本地端口转发（`ssh -L`）

### T1. 错误类型与数据模型

- [ ] **测试**：`ForwardError` 各变体的构造和 Display
- [ ] **测试**：`ForwardConfig` TOML 序列化 / 反序列化（各字段组合）
- [ ] **测试**：`ForwardLifecycle` 枚举序列化
- [ ] **测试**：`ForwardKind` 枚举序列化
- [ ] **实现**：`ForwardError` 枚举（design 第 5 节）
- [ ] **实现**：`ForwardConfig` 数据结构（design 第 2.1 节）
- [ ] **验收**：`cargo test` 通过，覆盖正常 / 异常 / 边界

### T2. DirectTcpipChannel 流包装

- [ ] **测试**：`DirectTcpipChannel` 的 AsyncRead 实现（使用 mock Channel，注入 `ChannelMsg::Data` / `ChannelMsg::Eof` / `ChannelMsg::Close`）
- [ ] **测试**：`DirectTcpipChannel` 的 AsyncWrite 实现（验证写出的字节正确）
- [ ] **测试**：`poll_shutdown` 发送 Close 消息
- [ ] **测试**：读写背压行为（满时返回 Poll::Pending）
- [ ] **实现**：`DirectTcpipChannel` struct + AsyncRead/AsyncWrite impl
- [ ] **验收**：`cargo test` 通过，mock Channel 测试覆盖率 ≥ 95%

### T3. LocalForwardService 核心

- [ ] **测试**：本地转发正常启动并监听指定端口（用 fake SSH server + 真实 TcpStream 连接本地端口 → 验证数据通过 tunnel 到达远端）
- [ ] **测试**：本地端口被占用返回 `PortConflict`，不静默换端口（mock `TcpListener::bind` 返回 AddrInUse）
- [ ] **测试**：本地转发 accept 多个连接，每个独立建 direct-tcpip 通道
- [ ] **测试**：远端 direct-tcpip 打开失败时，关闭已 accept 的本地 stream，继续 accept 循环（单次失败不终止整个转发）
- [ ] **测试**：任一端数据流关闭后，两端资源正确释放（无泄漏）
- [ ] **实现**：`LocalForwardService::run()` 主循环
- [ ] **实现**：错误到 ForwardError 的映射（bind 失败 → PortConflict）
- [ ] **验收**：`cargo test` 通过，集成测试端到端可用

### T4. ForwardManager 统一入口

- [ ] **测试**：`create()` 返回正确的 forward_id，转发状态为 Listening/Active
- [ ] **测试**：`close()` 关闭指定转发，listener 不再 accept
- [ ] **测试**：`close_by_owner()` 一次性关闭该 owner 的全部转发，其他 owner 的不受影响
- [ ] **测试**：`list()` / `get()` 返回正确的运行时信息
- [ ] **测试**：关闭已释放 Transport 的转发时优雅清理（Transport 先释放 → close_by_transport 被调用 → 不 panic）
- [ ] **实现**：`ForwardManager` struct（design 第 3.1 节）
- [ ] **实现**：内部 HashMap + RwLock 状态管理
- [ ] **实现**：字节计数（bytes_in / bytes_out）
- [ ] **验收**：`cargo test` 通过，并发访问测试通过

### T5. FFI 绑定（Phase 1）

- [ ] **测试**：uniffi Record `ForwardConfig` / `ForwardRuntimeInfo` 导出正确
- [ ] **测试**：`forward_create` / `forward_close` / `forward_list` / `forward_get` / `forwards_close_by_owner` FFI 函数签名正确导出
- [ ] **测试**：`ForwardError` 变体通过 FFI 正确映射到 Swift 可区分的错误类型
- [ ] **实现**：panda-ffi 新增 ForwardConfig / ForwardRuntimeInfo 定义 + ForwardError Enum
- [ ] **实现**：panda-ffi 新增 5 个转发 FFI 函数，桥接到 ForwardManager
- [ ] **验收**：`cargo test` 通过，Swift 侧能 import 新类型和函数

### T6. 停机链条集成

- [ ] **测试**：标签页关闭 → `WorkspaceService` 触发 → `forwards_close_by_owner(tab_id)` 被调用 → 转发静默关闭
- [ ] **测试**：SSH Transport 释放 → ForwardManager 检测到 → `close_by_transport` 自动清理
- [ ] **实现**：在标签页关闭和 Transport 释放的现有链条中追加转发清理
- [ ] **验收**：停机链条不遗漏转发，`cargo test` 全绿

### Phase 1-验收

- [ ] `cargo test` 全绿
- [ ] 覆盖率 ≥ 95%
- [ ] 本地转发端到端验证：真实 SSH server + 真实本地端口连接
- [ ] 平台条件编译合规：业务逻辑全部在 Rust 核心

---

## Phase 2：反向端口转发（`ssh -R`）

> 前置：Phase 1 全部验收通过

### T7. Russh tcpip-forward 抽象验证

- [ ] **集成测试**：连接真实 SSH server → 请求 `tcpip-forward` → 验证服务端接受 → 外部工具（如 nc）连接远端绑定端口 → 数据回传到本地 → 双向桥接
- [ ] **实现**：`SshTransport::request_tcpip_forward()` 封装 russh API，返回可 accept 的 stream

### T8. RemoteForwardService 核心

- [ ] **测试**：正常反向转发——请求 tcpip-forward 成功 → 远端连接到达 → 回连本地目标 → 双向桥接
- [ ] **测试**：服务端拒绝 tcpip-forward → 返回 `ServerForwardDenied` 错误（含服务端返回的 reason 文本）
- [ ] **测试**：本地目标不可连接 → 关闭已建立的 direct-tcpip（远端回连的那个），继续等待下次远端连接
- [ ] **测试**：远端回连的 direct-tcpip 数据流正常双向桥接
- [ ] **实现**：`RemoteForwardService::run()` 主循环
- [ ] **验收**：`cargo test` 通过，集成测试端到端可用

### T9. ForwardManager 反向转发集成

- [ ] **测试**：ForwardManager 能创建 / 关闭 / 列出 `ForwardKind::Remote` 的转发
- [ ] **测试**：不同 kind 的转发在同一 ForwardManager 下共存，互不干扰
- [ ] **实现**：在 ForwardManager 中按 ForwardKind 分发到对应 Service
- [ ] **验收**：`cargo test` 通过

### T10. FFI 绑定（Phase 2）

- [ ] **测试**：Reverse Forward 创建和关闭通过 FFI 正确导出
- [ ] **验收**：`cargo test` 通过，Swift 侧能创建反向转发

### Phase 2-验收

- [ ] `cargo test` 全绿
- [ ] 覆盖率 ≥ 95%
- [ ] 反向转发端到端验证（可搭建简单 SSH server + nc 客户端测试）

---

## Phase 3：SOCKS5 动态转发 + 完整所有权管理

> 前置：Phase 1 + 2 全部验收通过

### T11. SOCKS5 协议处理

- [ ] **测试**：SOCKS5 握手——客户端发送 `[0x05, 0x01, 0x00]`（版本 + 1 method + 无认证）→ 响应 `[0x05, 0x00]`
- [ ] **测试**：SOCKS5 CONNECT IPv4——客户端发送 CONNECT 请求（目标 `10.0.0.1:80`）→ 响应 `0x00`（成功）+ bound address → 在 SSH 上打开 direct-tcpip 到 `10.0.0.1:80`
- [ ] **测试**：SOCKS5 CONNECT 域名——客户端发送 CONNECT（目标 `example.com:443`）→ direct-tcpip 到 `example.com:443`（让 SSH server 做 DNS 解析）
- [ ] **测试**：SOCKS5 错误响应——direct-tcpip 打开失败时返回正确的 SOCKS5 reply code（`0x01` 通用失败 / `0x04` host unreachable / `0x05` connection refused）
- [ ] **测试**：非法 bind address `0.0.0.0` → 拒绝（已在设计中要求，在 bind 前验证）
- [ ] **测试**：并发处理——同时 accept 多个 SOCKS5 客户端，每个独立建 direct-tcpip（不同 target），互不干扰
- [ ] **实现**：`handle_socks5()` 协议处理函数
- [ ] **实现**：SOCKS5 reply code 映射（Rust 错误类型 → SOCKS5 code）
- [ ] **验收**：`cargo test` 通过（SOCKS5 单元测试 + mock Channel 测试）

### T12. DynamicForwardService 核心

- [ ] **测试**：完整 SOCKS5 动态转发——本地 `127.0.0.1:1080` 监听 → SOCKS5 客户端连接 → 多个 CONNECT 请求正确转发
- [ ] **测试**：每个 CONNECT 请求在独立 task 中处理，不阻塞其他请求
- [ ] **测试**：关闭 SOCKS5 listener → 所有活跃 direct-tcpip 通道在超时后关闭或立即关闭
- [ ] **实现**：`DynamicForwardService::run()` 主循环（listener accept → spawn handle_socks5）
- [ ] **验收**：`cargo test` 通过

### T13. Independent 生命周期 + 持久化

- [ ] **测试**：`ForwardLifecycle::Independent` 转发持久化到 `port_forwarding.toml`
- [ ] **测试**：App 启动时 `start_independent_forwards()` 从 TOML 恢复全部 Independent 转发并自动启动
- [ ] **测试**：启动恢复时，已绑定端口被占用 → 跳过恢复并记录错误，不阻塞其他恢复项
- [ ] **测试**：已恢复的转发状态正确（Listening/Active，有正确的 host_id / owner_id）
- [ ] **测试**：TOML 文件损坏时容错——跳过损坏条目，记录错误，不 panic
- [ ] **实现**：`ForwardStore`（TOML 文件读写）
- [ ] **实现**：`ForwardManager::start_independent_forwards()`
- [ ] **验收**：`cargo test` 通过

### T14. 所有权独占验证 + iOS 约束

- [ ] **测试**：同一 owner 持有多条独立转发时，SSH Transport 按 owner 独占分配
- [ ] **测试**：尝试跨 owner 共享 Transport 时 → 返回 `TransportAlreadyOwned` 错误
- [ ] **测试**：iPadOS 前台恢复检测——所有 Independent 转发尝试重新 bind + 检查 Transport → 失败的提示重建
- [ ] **实现**：ForwardManager 中的 owner 独占验证
- [ ] **实现**：iPadOS 恢复检测（平台条件编译，只在 iOS 生效）
- [ ] **验收**：`cargo test` 通过

### Phase 3-验收

- [ ] `cargo test` 全绿
- [ ] 覆盖率 ≥ 95%
- [ ] SOCKS5 动态转发端到端验证（用 SOCKS5 客户端工具如 `curl --socks5` 测试）
- [ ] 独立转发重启恢复验证

---

## Phase 4：SwiftUI 管理面板 + 完整 UI

> 前置：Phase 3 全部验收通过

### T15. 转发列表视图

- [ ] 新增转发面板视图（Tab 或 Drawer）
- [ ] 列表展示：id / kind / 本地地址 / 目标 / owner / 状态 / 字节计数
- [ ] 状态颜色区分：Listening / Active / Error
- [ ] 独立转发显示在专门区域，区分"随标签页转发"

### T16. 创建表单

- [ ] 本地转发表单：本地地址（默认 127.0.0.1）、本地端口、远端地址、远端端口、生命周期（WithTab / WithConnection / Independent）
- [ ] 反向转发表单：远端绑定地址 / 端口、本地目标地址 / 端口
- [ ] SOCKS5 表单：本地地址（仅 127.0.0.1，禁止 0.0.0.0）、本地端口
- [ ] owner 自动填充（当前标签页 ID）

### T17. 交互

- [ ] 一键关闭转发
- [ ] 字节计数实时刷新（按 ForwardManager 推送或轮询）
- [ ] 端口冲突时展示明确错误
- [ ] 服务端拒绝时展示服务端返回的 reason

### T18. 停机链条追加（UI 提示）

- [ ] 标签页关闭确认弹窗中，若该标签页有关联转发，提示"将同时关闭 N 条端口转发"
- [ ] 不阻止关闭，仅增加可见性

### Phase 4-验收

- [ ] `xcodebuild` macOS/iOS 双端通过
- [ ] 手动验证全部转发类型的创建 / 运行 / 关闭 / 恢复
- [ ] SwiftUI 侧 XCTest 覆盖

---

## 依赖关系

```
Phase 0 (Spike R1-R3) ──┬──→ Phase 1 (本地转发) ──┬──→ Phase 2 (反向转发) ── Phase 3 (SOCKS5 + 所有权) ── Phase 4 (SwiftUI)
                         │                              │
                         │  共享 DirectTcpipChannel 流包装（可被 proxy-jump 前置复用）
```

### 关键依赖链

```
T1 ─┐
T2 ─┤──→ T3 ──→ T4 ──→ T5 ──→ T6 ── Phase 1 验收
    │
    └──→ T7 ──→ T8 ──→ T9 ──→ T10 ── Phase 2 验收
                           │
                           └──→ T11 ──→ T12 ──┐
                                               ├──→ T13 ──→ T14 ── Phase 3 验收
                                               │
                                               └──→ T15 ──→ T16 ──→ T17 ──→ T18 ── Phase 4 验收
```

### 可并行项

- T1（数据模型）可与 Spike R1-R3 并行写测试 + 实现（只依赖 ForwardError / ForwardConfig 的定义，不依赖 russh API）
- Phase 3 T13（独立持久化）和 T11（SOCKS5）可并行（互不依赖）
- Phase 4 的 T15-17 可在 Phase 3 验收后并行开发

---

## 预估工作量汇总

| 阶段 | 工作量 | 说明 |
|------|--------|------|
| Phase 0 — Spike R1-R3 | 2h | 前置验证 russh API |
| Phase 1 — 本地转发 | 10h | T1-T6，核心服务 + FFI + 停机链条 |
| Phase 2 — 反向转发 | 6h | T7-T10，复用 Phase 1 的 DirectTcpipChannel |
| Phase 3 — SOCKS5 + 所有权 | 8h | T11-T14，SOCKS5 协议 + 持久化 + 所有权独占 |
| Phase 4 — SwiftUI | 4h | T15-T18，管理面板 |
| 评审 + 覆盖率补齐 | 3h | |
| **总计** | **约 33h** | |

---

## 风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| russh 0.62 direct-tcpip / tcpip-forward API 签名不符预期 | 中 | Phase 0 Spike 前置验证；如果失败，升级 russh 到最新稳定版 |
| SOCKS5 协议边界条件（认证、UDP、IPv6） | 低（当前只支持最小子集） | T11 测试覆盖已声明支持的子集；后续追加不紧急的扩展 |
| 数据流双向拷贝的背压与清理 | 中 | T3 显式测试端："任一断开另一端正确清理" + "本地关闭 → 远端 direct-tcpip 关闭" + "远端关闭 → 本地关闭" |
| iPadOS 后台恢复行为 | 中 | T14 iPadOS 恢复检测有测试覆盖，条件编译只在 iOS 生效不影响 macOS |
| ForwardManager 状态并发 | 低 | 用 RwLock 保护；测试覆盖多线程 create/close/list 并发 |
| 与 proxy-jump 的 Transport 竞争 | 低 | 两功能都通过 ForwardManager 的 owner 独占规则隔离，不跨 owner 共享 Transport |
