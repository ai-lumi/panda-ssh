## 1. 传输速度计算单元

### 测试

- [x] 1.1 编写 `TransferSpeedCalculator` 测试：
  - 正常流程：给定固定时间窗口内的进度点，返回正确实时速度。
  - 意外操作：进度回退或乱序到达时，计算结果不崩溃、不返回负值。
  - 边界条件：窗口内只有一个数据点时，退化到与起始点计算；窗口为空时速度为 0。
- [x] 1.2 编写总速度测试：
  - 正常流程：给定起始时间与当前已传字节，返回正确平均速度。
  - 意外操作：起始时间晚于当前时间（时钟异常）时返回 0 或安全值。
  - 边界条件：已传字节为 0 时总速度为 0；时间差极小时按实际字节数计算。
- [x] 1.3 编写速度格式化测试：
  - 正常流程：B/s、KB/s、MB/s、GB/s 单位自动切换。
  - 意外操作：负值速度格式化为 "0 B/s" 或等效安全文案。
  - 边界条件：0 B/s、1023 B/s、1024 B/s 等临界值格式化正确。

### 实现

- [x] 1.4 在 `apple/PandaSSH/Transfers/`（或等效目录）新增 `TransferSpeedCalculator.swift`，支持：
  - 记录 `(timestamp, bytes)` 进度点。
  - 2 秒滑动窗口实时速度。
  - 基于任务起始时间的总速度。
  - 剩余时间估算（速度 > 0 且剩余字节已知时）。
- [x] 1.5 新增 `formatSpeed(_:)` 格式化函数，单位按 1024 进制切换。
- [x] 1.6 运行对应 Swift target 的速度计算单元测试并确保通过。

## 2. TransferTask / TransferStore 集成

### 测试

- [x] 2.1 编写 `TransferTask` 速度属性测试：
  - 正常流程：模拟持续进度更新，`liveSpeed` 与 `totalSpeed` 反映计算值。
  - 意外操作：任务状态变为 `failed` / `cancelled` 后，速度归零或不再更新。
  - 边界条件：新创建任务无进度点时速度为 0。

### 实现

- [x] 2.2 在 `TransferTask` 中集成 `TransferSpeedCalculator`，在 `transferred` 更新时同步记录时间戳。
- [x] 2.3 暴露 `liveSpeed`、`totalSpeed`、`estimatedTimeRemaining` 等计算属性。
- [x] 2.4 运行 `TransferStore` 相关单元测试并确保通过。

## 3. 传输面板 UI 展示

### 测试

- [x] 3.1 编写 UI 展示逻辑测试（使用 Mock 数据）：
  - 正常流程：进行中的任务显示实时速度、总速度、剩余时间。
  - 意外操作：已完成/失败任务不显示剩余时间或实时速度文案合理。
  - 边界条件：速度为 0 时显示 "0 B/s" 或 "计算中"，无异常布局。

### 实现

- [x] 3.2 在 `apple/PandaSSH/Transfers/TransferRow.swift`（或等效视图）中增加速度标签区域，展示实时速度、总速度、剩余时间。
- [x] 3.3 调整进度条与速度标签的 macOS / iPadOS 共用布局。
- [x] 3.4 运行对应 Swift target 的 UI 相关单元测试（如 `TransferStoreTests`）并确保通过。

## 4. 验收与归档

- [x] 4.1 运行 `cargo test --workspace` 全绿（确认无 Rust 侧回归）。
- [x] 4.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过。
- [x] 4.3 运行 `apple/Scripts/build-rust.sh` 与 `xcodegen` 后，macOS / iOS 双端 `xcodebuild` 编译通过。
- [x] 4.4 将本 change 的 spec delta 合并回 `openspec/specs/`。
- [x] 4.5 归档 change 到 `openspec/changes/` 的归档目录。
