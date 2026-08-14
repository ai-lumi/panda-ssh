## 1. 修复路径映射

- [x] 1.1 `TransferStore.add` 按 `direction` 将 `source`/`destination` 映射为正确的 `localPath`/`remotePath`。
- [x] 1.2 `MockTransferSource.enqueueTransfer` 同步修正 source/destination 保存。

## 2. 测试

- [x] 2.1 新增 `TransferSourceSpy` 与方向映射测试用例。
- [x] 2.2 `xcodebuild -scheme PandaSSH-macOS test` 通过（161 tests）。

## 3. 归档

- [ ] 3.1 `openspec validate transfer-download-path-fix --strict` 通过。
- [ ] 3.2 归档本变更。
