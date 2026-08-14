## Why

用户反馈两个 UX 问题：

1. 侧栏树形结构中单击主机无法选中，导致右侧详情面板不切换。
2. SFTP 文件列表缺少右键（macOS）/长按（iPadOS）上下文菜单，操作不够便捷。

## What Changes

- `HostRowView` 移除可能拦截 List 选中的双击手势，改为显式单击选中。
- `HostRowView` 仍保留 contextMenu，可通过右键/长按打开终端、SFTP、编辑、移动分组、删除。
- SFTP 文件行增加 contextMenu：
  - 目录：进入
  - 本地文件/目录：上传
  - 远程文件/目录：下载

## Non-Goals

- 不替换为 AppKit 原生 OutlineView。
- 不新增删除/重命名等需额外 FFI 的菜单项。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace`: 侧栏主机单击选中和 SFTP 文件行右键/长按菜单。

## Impact

- 仅影响 SwiftUI 视图层，后端 FFI 无变化。
- macOS / iPadOS 双端共享源码同时生效。
