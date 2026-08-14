## 1. 任务组数据模型

- [x] 1.1 `TransferTask` / `TransferRecord` 新增 `groupID` 与 `groupName`。
- [x] 1.2 `TransferStore` 维护 `groupInfo` 映射并在刷新时回填。
- [x] 1.3 `TransferStore.add` 支持传入 `groupID` / `groupName`。

## 2. 目录上传拆分

- [x] 2.1 `PandaCoreBridge` 封装 `sftpCreateDir`。
- [x] 2.2 `SftpSessionStore` 实现本地目录递归枚举与远端目录创建。
- [x] 2.3 为每个文件创建带同一 groupID 的上传任务。

## 3. 目录下载拆分

- [x] 3.1 `SftpSessionStore` 实现远端目录递归枚举（复用 `sftpList`）。
- [x] 3.2 本地目录预创建。
- [x] 3.3 为每个文件创建带同一 groupID 的下载任务。

## 4. 多选规则

- [x] 4.1 远程多选按条目类型区分为独立任务或任务组。
- [x] 4.2 本地文件选择器返回的路径按类型区分。

## 5. 组级操作与 UI

- [x] 5.1 `TransferStore` 实现 `cancelGroup` / `retryGroup`。
- [x] 5.2 `TransferPanelView` 按组聚合渲染。
- [x] 5.3 组头显示批量操作按钮。

## 6. 验证

- [x] 6.1 `cargo test` 全绿。
- [x] 6.2 `xcodegen` → `xcodebuild` 测试通过（194 tests）。

## 7. 归档

- [ ] 7.1 `openspec validate directory-transfer-task-groups --strict` 通过。
- [ ] 7.2 归档本变更。
