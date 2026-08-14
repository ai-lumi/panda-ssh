## Why

在修复 SFTP 双击进入目录后，发现两个新的 UX 问题：

1. 文件行（非目录）无法通过单击选中，导致无法触发上传/下载操作。
2. 用户进入深层子目录后，缺少明显的一键返回顶级目录入口。

## What Changes

- 为文件行增加 `.contentShape(Rectangle())`，使整行可点击，确保 List 单击选中可靠。
- 仅对目录行附加双击手势；文件行不附加手势，避免干扰 List 选中。
- 将栏头标题「本地 / 远程 — host.name」改为可点击按钮，点击后返回该面板顶级目录。

## Non-Goals

- 不引入 AppKit 原生表格组件。
- 不实现多选、拖拽、列视图。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace`: SFTP 文件列表单击选中和栏头返回顶级目录行为。

## Impact

- 仅影响 `SftpTabView`；后端无变化。
- macOS / iPadOS 双端共享源码同时生效。
