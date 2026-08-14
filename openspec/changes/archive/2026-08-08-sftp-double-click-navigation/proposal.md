## Why

SFTP 文件列表原设计为「单击选中目录，再次点击同一目录进入」，但 SwiftUI `List(selection:)` 的绑定在点击已选中项时不会触发 setter，导致用户无法进入子目录。用户反馈该交互不自然，应使用与系统文件管理器一致的双击进入方式。

## What Changes

- SFTP 文件行支持双击目录进入子目录。
- 单击仍用于选中（与高亮），与 macOS Finder / iOS 文件 App 一致。
- 移除原先不可靠的「再次点击已选中目录进入」逻辑。

## Non-Goals

- 不替换为 `NSOutlineView`/`NSTableView` 等 AppKit 组件；继续使用 SwiftUI `List`。
- 不重构成完整 Finder 级文件浏览器（拖拽、多选、列视图等）。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace`: SFTP 文件列表的目录进入交互由「单击已选中」改为「双击」。

## Impact

- 仅影响 `SftpTabView` 的文件列表交互；后端 FFI 与模型层无变化。
- macOS / iPadOS 双端共享源码同时生效。
