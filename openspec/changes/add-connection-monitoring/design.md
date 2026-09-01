## Context

见 proposal.md - Why。当前 `SshSession` 调用 `russh::client::connect` 并仅保留 handle；连接池只保留 `(host_id, credentials)` 到会话的映射，无法读取实际 Socket 状态或在其 I/O 边界计量。shell、SFTP 和批量传输各自开 channel，没有统一生命周期模型。Swift 的 `WorkspaceStore` 有标签连接状态，但它不是底层连接事实来源。

## Goals / Non-Goals

**Goals:**
- 让 Rust core 作为每条实际 TCP Socket、SSH 会话与通道状态及 Socket I/O 字节数的唯一事实来源。
- 以快照读取替代事件流或后台轮询；UI 可自行定时刷新，但默认不触发网络 I/O。
- 复用现有连接池和全局 tokio runtime，并保持所有 FFI 导出同步。

**Non-Goals:**
- 不尝试从 russh 或系统网络栈推导加密后 TCP 包字节数。
- 不把监控作为连接保活或自动恢复机制。
- 不增加外部依赖、平台专属 API 或遥测上报服务。

## Decisions

### 决策 1：持有实际 Socket 并分层报告状态

选择先显式建立 `tokio::net::TcpStream`，把同一 stream 交给 russh 的 `connect_stream`，并保留对实际 Socket 的状态查询与 I/O 包装。监控模型严格分为 TCP Socket、SSH 会话和 SSH 通道三层：Socket 层报告内核 TCP 状态；SSH 层报告握手/认证/连接状态；通道层报告 shell/SFTP/exec 状态。这样 TCP 已建立但 SSH 或 shell 已不可用时不会被误报为健康。

替代方案：继续调用 `client::connect` 后从 handle 推测 Socket 状态。放弃原因：handle 不暴露实际 Socket，任何推断都不能满足“Socket 自身完整状态”的要求。

### 决策 2：Socket I/O 字节为流量唯一口径

选择包裹实际 Socket 的 `AsyncRead`/`AsyncWrite`，累计交给 russh 前后的成功读写字节；该计数包含 SSH 加密载荷，覆盖全部 SSH 通道并避免通道与连接总量重复相加。通道逻辑字节作为会话明细独立展示，不与 Socket 总流量混为同一指标。UI 必须说明 Socket 字节不含 TCP/IP 头和内核重传。

替代方案：汇总 shell/SFTP/exec 逻辑字节作为“总流量”。放弃原因：SSH 协议开销、keepalive 与未映射通道会遗漏，且多层聚合容易重复计数。

### 决策 3：遥测注册表独立于连接池键

选择在 core 内维护线程安全的运行时遥测注册表，以随机/递增的非敏感连接 ID 索引连接状态和通道记录；连接池保存该 ID 与会话的关联。凭据绝不进入遥测记录或 FFI 返回值。连接释放会更新或移除记录，通道关闭会写入终态。

替代方案：把完整 telemetry 放进 `PoolEntry`。放弃原因：shell/SFTP/批量传输需要跨多个持有者安全更新，独立共享状态更能避免锁住连接池执行网络操作。

### 决策 4：健康检查使用现有的无副作用通道打开能力

选择对指定的活动 `SshSession` 尝试打开一个 session channel，并立即关闭/释放它；成功为健康，失败为不可用。只由明确用户操作调用，且对同一连接施加最小间隔以防止重复点击造成探测风暴；间隔内返回最近结果或未知。该检查不认证、不执行命令、不读取终端数据。

替代方案：执行远端命令或周期性 keepalive。放弃原因：命令有副作用/权限语义，周期探测会额外产生网络流量并与用户期望的“监控”混淆。

### 决策 5：Swift 采用独立快照 Store 与可重用页面

选择 `ConnectionMonitorStore` 在非主线程调用同步 FFI，再在主线程发布模型；页面只渲染快照和空/错误状态。macOS 通过侧栏或窗口入口、iPadOS 通过侧栏页面进入同一 SwiftUI 视图；不得用 `#if os()` 改变业务规则。

替代方案：让 `WorkspaceStore` 自行计算连接数据。放弃原因：它无法覆盖没有标签但仍因传输保活的连接，也会复制 Rust 业务状态。

## Risks / Trade-offs

- [不同目标系统能报告的内核 TCP 细节不同] → 使用跨平台的公共状态枚举；无法取得时显式显示「不可获取」，不推断状态。macOS/iPadOS 优先实现其可用的内核状态查询，Linux 编译保留安全回退。
- [Socket 包装与 russh 的异步所有权集成复杂] → 以 `connect_stream` 作为唯一接入点；用 fake server 验证读写、关闭和错误路径。
- [并发更新产生锁竞争] → 遥测更新使用短临界区、原子计数或细粒度共享状态，网络 await 不持有注册表锁。
- [健康检查可能使刚断线状态变化] → 仅用户触发、显示检查时间与结果，不将结果解释为永久可用性。
- [通道与标签关联并非总能得到] → 关联字段为可选；传输后台连接仍必须可被监控。

## Migration Plan

1. 先加入仅内存、默认关闭前无外部副作用的 core 遥测模型与测试。
2. 接入 FFI 和 Swift 页面；旧连接与标签 API 保持兼容。
3. 完成 Rust/Swift 测试、构建和覆盖率验证后归档变更并合并 spec delta。
4. 若出现统计异常，移除 UI 入口或禁用遥测采集即可回滚；遥测不持久化，不需数据迁移。
