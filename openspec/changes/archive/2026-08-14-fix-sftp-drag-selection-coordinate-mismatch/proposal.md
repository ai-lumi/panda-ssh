## Why

SFTP 文件栏的框选多选在 macOS 端出现坐标错位：拖拽产生的蓝色选区矩形与实际被选中的条目不一致（选区覆盖下方条目，但系统仍保留/选中上方条目）。该问题导致用户无法直观、可靠地进行批量框选，违背了 OpenSpec `sftp-batch-transfer` 中框选行为的规定，因此需要修复实现层面的坐标对齐。

## What Changes

- 将 `SftpTabView.fileList` 的底层容器从 SwiftUI `List` 替换为 `ScrollView + LazyVStack`，消除 `List` 内部 content inset 导致的 `DragGesture` 坐标与 `GeometryReader` 行 frame 原点不一致。
- 保留原有交互：单击/双击、Command 追加、多选复选框、框选矩形可视化、空目录提示均不变。
- 在 `project.yml` 中显式声明 `PandaSSH-macOS` / `PandaSSH-iOS` scheme，并绑定对应单元测试 target，确保 XcodeGen 生成的工程可直接运行双端测试。

## Capabilities

### New Capabilities

无。本次为纯实现修复，不引入新的规格能力。

### Modified Capabilities

无。`sftp-batch-transfer` 规范已定义框选行为，本次仅修正实现使其符合规范。

## Impact

- **Swift 代码**：`apple/PandaSSH/Workspace/SftpTabView.swift` 的 `fileList` 视图实现。
- **工程配置**：`apple/project.yml` 新增 `schemes` 段，影响 XcodeGen 生成的 `.xcodeproj`。
- **平台**：同时影响 macOS 与 iPadOS 双端（共享源码），但框选手势仅在 macOS 侧启用。
- **测试**：双端单元测试均需保持通过；无需新增测试，因为视图层坐标对齐难以在 XCTest 中直接断言，现有功能测试覆盖选择模型与批量传输逻辑。

## Non-goals

- 不修改 `sftp-batch-transfer` 规范文本。
- 不新增框选手势（iPadOS 接鼠标的框选已在现有代码中通过 `simultaneousGesture` 支持，macOS 同样逻辑）。
- 不改动文件传输、覆盖确认、任务组等批量传输后端逻辑。
