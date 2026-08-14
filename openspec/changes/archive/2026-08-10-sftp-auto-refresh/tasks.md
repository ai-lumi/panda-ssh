## 1. 自动刷新

- [x] 1.1 `SftpSessionStore` 增加 Combine 订阅监听 `TransferStore.$tasks`。
- [x] 1.2 上传完成后刷新远程面板。
- [x] 1.3 下载完成后刷新本地面板。
- [x] 1.4 使用 `refreshedTaskIDs` 去重。

## 2. 手动刷新按钮

- [x] 2.1 `SftpTabView.paneHead` 增加刷新按钮。
- [x] 2.2 点击刷新当前面板。

## 3. 验证

- [x] 3.1 `xcodebuild -scheme PandaSSH-macOS test` 通过（185 tests）。

## 4. 归档

- [ ] 4.1 `openspec validate sftp-auto-refresh --strict` 通过。
- [ ] 4.2 归档本变更。
