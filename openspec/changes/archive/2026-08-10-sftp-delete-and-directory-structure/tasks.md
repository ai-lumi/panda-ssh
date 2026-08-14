## 1. SFTP 删除功能

- [x] 1.1 `PandaCoreBridge` 封装 `removeRemoteFile`（区分文件/目录）。
- [x] 1.2 `SftpSessionStore` 增加 `deleteLocal` / `deleteRemote`，删除后刷新面板。
- [x] 1.3 `SftpTabView` 上下文菜单增加「删除」按钮。
- [x] 1.4 `SftpTabView` 增加删除二次确认 alert。

## 2. 目录传输结构保持

- [x] 2.1 `uploadSelected` 目录走 `batchUpload(localPaths: [source])`。
- [x] 2.2 `downloadSelected` 目录走 `batchDownload(sources: [source])`。
- [x] 2.3 演示/测试模式保持 placeholder 单任务行为。

## 3. 验证

- [x] 3.1 `cargo test` 全绿。
- [x] 3.2 `xcodegen` → `xcodebuild -scheme PandaSSH-macOS test` 通过（191 tests）。

## 4. 归档

- [ ] 4.1 `openspec validate sftp-delete-and-directory-structure --strict` 通过。
- [ ] 4.2 归档本变更。
