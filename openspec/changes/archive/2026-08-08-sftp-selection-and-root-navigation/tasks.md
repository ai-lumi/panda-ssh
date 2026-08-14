## 1. 文件行单击选中修复

- [x] 1.1 `fileRow` 增加 `.contentShape(Rectangle())` 让整行可点击。
- [x] 1.2 通过 `applyIf` 仅对目录行附加双击手势，文件行不附加。

## 2. 返回顶级目录

- [x] 2.1 paneHead 标题改为 Button，点击返回该面板 `nav.root`。

## 3. 验证

- [x] 3.1 `xcodebuild -scheme PandaSSH-macOS test` 通过。
- [x] 3.2 App 手动验证：文件可单击选中，目录可双击进入，标题可返回顶级。

## 4. 归档

- [ ] 4.1 `openspec validate sftp-selection-and-root-navigation --strict` 通过。
- [ ] 4.2 归档本变更。
