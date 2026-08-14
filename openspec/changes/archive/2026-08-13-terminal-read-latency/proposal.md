# Terminal Read Latency

## Why

当前 `TerminalTabView` 的读取循环固定在 `@MainActor` 上每 50ms 轮询一次，既引入最高 50ms 的输入延迟，又在主线程制造不必要的负载。通过将读取移到后台任务并缩短轮询间隔，可显著降低延迟并释放主线程。

## What Changes

- `startReading()` 去掉 `@MainActor`，在后台 `Task` 中执行 `shell_read`
- 轮询间隔从 50ms 降至 16ms（约 60fps），有数据时跳过 sleep 立即再次读取
- 数据通过 `MainActor.run` 异步提交到 `TerminalView`，避免主线程阻塞
- 取消时正常清理 `readTask`

## Capabilities

无 spec 级行为变更；纯实现优化，skip_specs。

## Impact

- `apple/PandaSSH/Workspace/TerminalTabView.swift` 读取循环改造

## Non-goals

- 本期不做 Rust 侧阻塞读 FFI（涉及 ShellSession 条件变量改造，复杂度较高，后续可考虑）
