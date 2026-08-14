## Context

SFTP 双栏文件浏览器使用 SwiftUI `List(selection:)` 管理选中态。原方案试图在 `selectionBinding` 的 setter 中检测「点击已选中目录」来进入目录，但 SwiftUI 不会为已选中项的重复点击调用 setter，导致子目录无法进入。

## Goals / Non-Goals

**Goals:**

- 目录进入交互稳定可用。
- 交互符合系统文件管理器习惯（单击选中、双击进入）。

**Non-Goals:**

- 不引入 AppKit 原生表格/大纲视图。
- 不实现列视图、多选、拖拽等高级文件管理功能。

## Decisions

### 双击进入目录

在 `fileList` 的每个 `fileRow` 上附加 `simultaneousGesture(TapGesture(count: 2))`：
- 仅对 `isDirectory == true` 的条目响应双击。
- 调用 `session.enterLocal(name)` / `session.enterRemote(name)`。
- 使用 `simultaneousGesture` 确保双击不拦截 List 的单击选中。

### 单击仅用于选中

`selectionBinding` 的 setter 只更新 `selectedLocal` / `selectedRemote`，不再尝试进入目录。

## Risks / Trade-offs

- iPadOS 上双击不如 macOS 常用，但仍为系统文件 App 支持的手势；无其他副作用。
- 继续使用 SwiftUI `List` 而非 AppKit 组件，保持跨平台共享源码。

## Migration Plan

无数据迁移。

## Open Questions

None.
