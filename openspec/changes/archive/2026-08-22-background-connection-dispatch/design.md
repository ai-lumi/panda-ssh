## Context

参见 proposal.md。现状关键事实（探索结论）：

- `panda-ffi::runtime()` 是多线程 tokio runtime（`Runtime::new()`），多次 `block_on` 在不同线程可并行——Rust 侧无并发瓶颈，瓶颈只在 Swift 侧把阻塞调用放在了主线程。
- 阻塞型 FFI 调用点与线程归属：
  - **主线程（需修复）**：`TerminalSessionStore.connect` → `PandaShellConnection.init` → `shellOpen`（完整握手 + PTY）；`SftpSessionStore.connect` → `resolveHomeDir` → `sftpHomeDir`（握手 + SFTP + home）；`SftpSessionStore` 的 `scanLocalItems`/`scanRemoteItems`/`checkUploadConflict`/`checkDownloadConflict`/`deleteRemoteCore`（@MainActor 类内同步 FFI）。
  - **已在后台（保持）**：`PandaCoreBackend.probePresentedKey`（`testConnection`，非隔离 async）；`RemoteFilePaneSource.list`（`sftpList`，非隔离 async）；`shellRead` 读循环（Task）。
- 现有代码**没有**任何 `Task.detached` / 后台队列设施，SFTP 的目录浏览恰好因类非隔离而隐式后台。

## Goals / Non-Goals

**Goals:**

- 连接建立（SSH shell、SFTP home 解析）与传输网络操作（扫描、冲突预检、删除）不再占用主线程。
- 多主机连接在后台并行握手，互不排队。
- FFI 保持同步导出，Rust 零改动。

**Non-Goals:**

- 不改 FFI 导出签名/异步化（spec 同步契约）。
- 不为毫秒级调用（`shellWrite`/`shellResize`/轮询/注册表快照）做后台化。
- 不改变连接池、TOFU 串行化、传输并发（Rust 侧语义不动）。

## Decisions

### D1：Swift 侧新增统一后台调度包装 `FFIBackground`（工具类型）

在 `apple/PandaSSH/PandaCoreBridge.swift` 内新增一个枚举/struct 提供静态方法：

```swift
enum FFIBackground {
    /// 在协作线程池执行同步 FFI 闭包，避免占用主线程。
    static func run<T>(_ op: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: op).value
    }
}
```

理由：
- `Task.detached` 默认跑在全局协作线程池（`DispatchQueue.global` 之上），多实例可并行，正是 spec 场景所需。
- 闭包是同步 FFI 调用，返回 `Sendable` 简单值即可；`await .value` 让 @MainActor 调用方无感等待、结果回主线程。
- 与项目现有模式（无任何后台调度设施）相比是增量最小方案；不引入 DispatchQueue 手动管理。
- 备选：给每个调用点单独写 `Task.detached`——重复样板且易漏，弃用。
- 备选：改 FFI 为 uniffi async 导出——违反 `ffi-bridge` 同步契约且需 Rust+绑定大改，弃用。

### D2：连接建立改为「后台执行 + 主线程收尾」

- `TerminalSessionStore.connect`（@MainActor）：把 `PandaShellConnection(...)` 创建包进 `Task.detached` 的 `FFIBackground.run`，创建成功后回主线程设置 `connection`/`phase`。`PandaShellConnection` 是类（引用类型），跨线程创建后仅主线程持有——`run` 返回 `PandaShellConnection` 时用 `@Sendable` 闭包注意：闭包内创建的连接在后台线程，但 `PandaShellConnection` 非 Sendable。处理：`FFIBackground.run` 只做「创建 handle」的同步部分（`shellOpen` 返回 `UInt64`），或把 `PandaShellConnection.init` 拆出静态 `open(hostID:...) -> UInt64`，`run` 返回 handle，主线程再包成对象。
- `SftpSessionStore.connect`（@MainActor）：`resolveHomeDir` 改为 `try await FFIBackground.run { ... sftpHomeDir ... }`，返回 `String`（Sendable），无对象跨越问题。

### D3：传输网络操作逐个包 `FFIBackground.run`

`scanLocalBatch`/`scanRemoteBatch`（返回 `[BatchItemRecord]`，Sendable）、`sftpCheckUploadConflict`/`sftpCheckDownloadConflict`（`RemoteFileConflictRecord?`）、`sftpRemoveFile`/`sftpRemoveDir`（`Void`）——调用点都在 @MainActor 的 `SftpSessionStore`，直接包 `run`。返回值均为值类型，安全。

### D4：多连接并行与 TOFU 串行化不冲突

TOFU 确认（`awaitTofuConfirmation`）在 AppModel 层按 host 串行化弹框，只影响「确认弹窗」不阻塞连接握手；连接握手本身在后台并行，符合 spec「多个连接并行建立」。

### D5：错误处理与日志

`FFIBackground.run` 抛出的错误原样向调用方传播（`try await`），各调用点现有 catch/日志逻辑不变；主线程状态机（connecting → shell/failed）不变。

## Risks / Trade-offs

- [`PandaShellConnection` 非 Sendable 跨线程创建] → 拆分 `open` 静态方法只跨线程传 `UInt64` handle；对象组装留在主线程。
- [`Task.detached` 优先级影响后台性能] → `.userInitiated` 匹配用户交互预期，与连接握手耗时（秒级）相比开销可忽略。
- [`FFIBackground.run` 泛型返回值需 `Sendable`] → 所有使用点返回值均为值类型/UInt64，无 Sendable 违例；测试中显式断言。
- [并发连接数多时 tokio worker 占满] → `Runtime::new()` 默认 worker = CPU 核数，连接握手以 IO 为主（tokio 事件循环可并发），瓶颈极小；若未来需要可加信号量，本期不做。

## Migration Plan

1. 新增 `FFIBackground` 工具 + 单元测试（断言后台执行、值回传）。
2. 逐调用点替换为 `FFIBackground.run`：先连接（shellOpen/sftpHomeDir），再传输操作（scan/conflict/delete）。
3. Swift 测试：断言连接建立期间主线程不被阻塞（如用 expectation + 主线程 tick 标记），多连接并行（两个连接同时进行，完成总时长 < 串行和）。
4. `cargo test` 不变（Rust 零改动）+ 双端 `xcodebuild` + 归档。