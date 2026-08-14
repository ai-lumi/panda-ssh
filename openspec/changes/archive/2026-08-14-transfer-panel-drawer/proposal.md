# Transfer Panel Drawer

## Why

当前传输任务面板在非紧凑宽度下内联在 SFTP 双栏浏览器右侧，永久占用 340px 空间，挤占了文件浏览区域。用户需要更大的文件浏览空间，同时能在需要时快速查看传输进度。

## What Changes

- 将 `SftpTabView.browser` 中的内联面板逻辑（`horizontalSizeClass != .compact` 时右侧内联）改为统一的抽屉式弹出框
- 使用 `ZStack` 包裹整个浏览器内容，面板以 `overlay` 形式悬浮在最上层
- 添加半透明黑色遮罩层（`Color.black.opacity(0.15)`），点击遮罩关闭面板
- 面板从右侧滑入/滑出（`.move(edge: .trailing).combined(with: .opacity)`），动画时长 0.25s
- 面板添加左侧阴影（`shadow(color: .black.opacity(0.2), radius: 16, x: -4, y: 0)`），增强悬浮层级感
- 紧凑与非紧凑宽度下行为一致：均使用悬浮抽屉，不再区分

## Impact

- `apple/PandaSSH/Workspace/SftpTabView.swift`
