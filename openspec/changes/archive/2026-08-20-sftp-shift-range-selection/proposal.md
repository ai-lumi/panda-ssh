## Why

当前 SFTP 文件栏只支持单点、⌘ 键逐个多选和拖拽框选，缺少与 Finder / Windows 资源管理器一致的 Shift+范围选择能力。用户在需要连续选中一大片文件（如日志序列、版本号连续的文件）时，必须逐一点击或依赖 macOS 拖拽框选，效率低且不符合桌面文件管理器习惯。补充 Shift+范围选择能显著降低多文件操作成本，并为后续键盘导航、全选等桌面级交互补齐基础。

## What Changes

- 在 `SftpSessionStore` 引入本地/远程栏的 **anchor（锚点）** 概念：最近一次非 Shift 点击的条目成为范围锚点。
- 支持 **Shift+单击** 选中从 anchor 到目标条目之间的全部条目（含两端），替换当前选中集合。
- 支持 **⌘+Shift+单击** 将上述范围追加到当前选中集合（与 Finder 行为一致）。
- 范围选择自动启用对应栏的多选模式，显示复选框。
- 进入目录、返回上级、切换目录后清除 anchor，避免跨目录范围选择产生意外。
- 补充 XCTest 覆盖正常范围、逆序范围、追加范围、目录切换后 anchor 重置等场景。

## Capabilities

### New Capabilities

- `sftp-range-selection`：定义 SFTP 本地/远程文件栏中 Shift+单击、⌘+Shift+单击进行范围选择的交互规则、anchor 生命周期及与现有多选模型的集成。

### Modified Capabilities

- `sftp-batch-transfer`：范围选择产生的新选中集合作为批量传输的源集合；现有批量上传/下载规则已覆盖“多个选中项”语义，本变更仅扩展选中方式，不改变批量传输本身的分组/递归/错误规则。

## Impact

- SwiftUI：`SftpTabView` 增加 Shift 修饰键检测与范围选择手势分发；`SftpSessionStore` 增加 anchor 状态与范围选择方法。
- 单元测试：`FilePaneNavigatorTests` / 新增 `SftpRangeSelectionTests` 覆盖范围选择行为。
- 平台：主要影响 macOS（有 Shift 修饰键）；iPadOS 外接键盘同样可用，纯触屏场景保持现有拖拽框选与显式多选模式。

## Non-goals

- 不重新设计批量传输的任务分组、递归扫描、冲突处理逻辑；范围选择只改变“哪些条目被选中”。
- 本次不实现键盘方向键 + Shift 的范围选择、Cmd+A 全选、触摸板双指滑动选择等扩展交互，仅聚焦 Shift+单击。
- 不修改 Rust 核心或 FFI 接口。
