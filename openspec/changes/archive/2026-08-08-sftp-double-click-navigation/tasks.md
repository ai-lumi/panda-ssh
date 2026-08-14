## 1. 交互修复

- [x] 1.1 `SftpTabView.fileList` 为目录行附加双击手势，调用 `enterLocal`/`enterRemote`。
- [x] 1.2 `SftpTabView.selectionBinding` 仅处理单击选中，不再尝试进入目录。
- [x] 1.3 使用 `simultaneousGesture` 避免双击拦截 List 单击选中。

## 2. 验证

- [x] 2.1 `xcodebuild -scheme PandaSSH-macOS test` 通过。
- [x] 2.2 App 手动验证：双击 SFTP 目录可进入子目录，单击可选中文件/目录。

## 3. 归档

- [ ] 3.1 `openspec validate sftp-double-click-navigation --strict` 通过。
- [ ] 3.2 归档本变更。
