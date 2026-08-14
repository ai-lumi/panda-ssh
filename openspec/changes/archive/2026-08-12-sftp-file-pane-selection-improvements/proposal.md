## Why

当前 SFTP 双栏文件列表采用自定义 `List` 实现多选与目录进入，但交互细节与 macOS Finder / iPadOS 文件 App 的习惯不符：多选模式缺少复选框、单击目录难以高亮、不支持 Command 键追加/取消多选、也不支持鼠标框选。这些别扭感让用户觉得“不像原生文件管理器”，降低了批量传输源选择的效率和可信度。

## What Changes

1. **多选模式显示复选框**：本地与远程文件栏进入多选模式后，每行左侧显示勾选框，明确表达选中状态。
2. **单选模式下单击高亮并互斥**：非多选模式下，单击任意条目（文件或目录）即高亮该条目，同时取消其他条目高亮；目录仍然可以通过双击进入。
3. **macOS Command 键多选**：在 macOS 端，按住 `⌘` 键单击条目可追加选中或取消选中单个条目，与 Finder 行为一致。
4. **鼠标框选多选**：在 macOS 端（以及 iPadOS 接入鼠标时），支持按住鼠标左键拖拽出矩形选区，框选范围内的条目全部进入选中状态。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `sftp-batch-transfer`：补充文件栏选中交互规则，包括复选框展示、单选高亮互斥、Command 键多选、鼠标框选多选，以及单选模式下目录可被单击高亮。

## Impact

- **SwiftUI 视图**：`SftpTabView` 的文件列表行、选中绑定、手势处理需要重写；macOS 端需监听 `⌘` 修饰键与鼠标拖拽事件。
- **状态模型**：`SftpSessionStore` 的 `selectedLocal` / `selectedRemote` 与 `selectedLocalItems` / `selectedRemoteItems` 需要统一或协调，使单选和多选模式共享同一组选中集合。
- **测试**：需新增 Swift 单元测试覆盖单选高亮、Command 多选、框选等交互路径；Rust 核心无需改动。
- **平台差异**：复选框与框选双端共用；`⌘` 键与鼠标拖拽仅在 macOS / iPadOS 接鼠标时生效，纯触摸 iPadOS 仍走现有显式多选模式。

## Non-goals

- 不替换为系统原生文件选择器（`NSOpenPanel` / `UIDocumentPicker`），双栏 SFTP 浏览器仍需自定义实现。
- 不修改批量传输核心算法（任务组、进度聚合、冲突处理）的行为，仅改变源项目选择方式。
- 不支持键盘方向键 + Space 选中等进阶键盘操作（未来可扩展）。
