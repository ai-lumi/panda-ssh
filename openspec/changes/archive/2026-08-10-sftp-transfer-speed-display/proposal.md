## Why

当前 SFTP 文件传输任务在 UI 上只展示进度百分比与已传/总字节数，缺少实时速度（当前瞬时速度）与总速度（本次传输平均速度）的直观展示。用户无法快速判断当前网络状况、预估剩余时间，体验不完整。本变更在传输面板中补充这两类速度指标。

## What Changes

- 在 SwiftUI 传输面板中为每个进行中的任务显示：
  - 实时速度（最近 N 秒内的平均瞬时速度）
  - 总速度（从开始到当前的整体平均速度）
  - 基于实时速度的预估剩余时间（可选展示）
- 补充可测的 ViewModel 逻辑：速度计算与时间窗口滑动。
- 不改动 Rust 核心传输接口；速度数据由 Swift 侧根据已有进度回调的时间戳推导。

## Capabilities

### New Capabilities

- `transfer-speed-display`：传输面板速度展示。覆盖实时速度、总速度、剩余时间估算的展示规则与计算规则。

### Modified Capabilities

- `sftp-transfer`：在「文件传输」相关要求下补充「传输进度需包含速度指标」的场景。

## Impact

- **macOS / iPadOS 双端**：共享的 `TransferStore` / `TransferTask` ViewModel 与 SwiftUI 视图需同时支持。仅涉及展示层，业务逻辑仍位于 Rust。
- **测试**：新增 Swift 单元测试验证速度计算（正常速度、零进度、时间窗口滑动、边界条件）。
- **依赖**：无新增外部依赖。

## Non-goals

- 不修改 panda-core 的传输回调粒度或 FFI 接口。
- 不实现全局带宽限制或传输速度历史持久化。
- 不针对 Mock 模式做特殊速度模拟（Mock 进度本身不变，速度显示为 0 或按测试注入值）。
