## Context

SFTP 文件浏览器在引入双击进入目录后，由于双击手势同时附加在文件行上，导致文件行单击选中失效；同时深层目录缺少快速返回顶级的入口。

## Goals / Non-Goals

**Goals:**

- 文件行可单击选中。
- 目录行可双击进入。
- 提供明显的一键返回顶级目录入口。

**Non-Goals:**

- 不替换为 AppKit 原生组件。
- 不实现 Finder 级高级功能。

## Decisions

### 整行可点击

为 `fileRow` 的 HStack 添加 `.contentShape(Rectangle())`，使点击区域覆盖整行。

### 条件手势

通过自定义 `applyIf` 扩展，仅在 `entry.isDirectory` 为 true 时附加双击手势。文件行无手势，List 默认单击选中可正常工作。

### 栏头标题返回顶级

将 paneHead 中的标题 `Text` 替换为 `Button`，点击后调用 `navigateLocal(to: nav.root)` / `navigateRemote(to: nav.root)`。

## Risks / Trade-offs

- 标题按钮可能被误认为纯装饰，但 macOS/iPadOS 用户通常能识别可点击标题。

## Migration Plan

无数据迁移。

## Open Questions

None.
