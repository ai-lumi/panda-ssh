## 1. 侧栏主机单击选中

- [x] 1.1 `HostRowView` 移除双击打开终端手势。
- [x] 1.2 `HostRowView` 增加显式单击选中手势，调用 `model.selectHost(host.id)`。

## 2. SFTP 右键/长按菜单

- [x] 2.1 `SftpTabView.fileRow` 增加 `local` 参数。
- [x] 2.2 `SftpTabView.fileRow` 增加 `.contextMenu`。
- [x] 2.3 实现 `fileContextMenu`：目录显示「进入」；本地显示「上传」；远程显示「下载」。

## 3. 验证

- [x] 3.1 `xcodebuild -scheme PandaSSH-macOS test` 通过（161 tests）。

## 4. 归档

- [ ] 4.1 `openspec validate sftp-context-menu-and-sidebar-selection --strict` 通过。
- [ ] 4.2 归档本变更。
