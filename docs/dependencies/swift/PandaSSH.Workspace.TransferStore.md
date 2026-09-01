# `PandaSSH.Workspace.TransferStore`

源文件：`apple/PandaSSH/Workspace/TransferStore.swift`

## 直接依赖

- `PandaSSH.Workspace.TransferSource`：单文件任务创建、控制与轮询。
- `PandaSSH.Workspace.BatchTransferSource`：批量任务创建、控制与轮询。
- `PandaSSH.Workspace.FFITransferSource`：生产实现。
- `PandaSSH.Workspace.MockTransferSource`：预览与测试实现。
- `Combine.ObservableObject`：发布任务列表变化。
- `Foundation.Timer`、`UUID`、`Date`：轮询、任务身份和速度计算。

## 被依赖方

- `PandaSSH.PandaSSHApp`：创建全局传输队列。
- `PandaSSH.Workspace.SftpSessionStore`：提交传输任务。
- `PandaSSH.Workspace.TransferPanelView`：显示与操作任务。
- `PandaSSH.Workspace.WorkspaceStore`：标签关闭时协调传输。

## 边界

该实体只维护 UI 任务投影与调度；真实 SSH/SFTP 业务规则由 Rust 侧任务实现。

