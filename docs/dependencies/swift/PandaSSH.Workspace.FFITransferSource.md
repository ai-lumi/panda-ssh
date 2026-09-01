# `PandaSSH.Workspace.FFITransferSource`

源文件：`apple/PandaSSH/Workspace/TransferStore.swift`

## 直接依赖

- `PandaSSH.Workspace.TransferSource`：单文件传输协议。
- `PandaSSH.Workspace.BatchTransferSource`：批量传输协议。
- UniFFI 生成的 `startTransfer`、`transfer*`、`startBatch*`、`batchTransfer*`：Rust 任务接口。
- `PandaSSH.Workspace.TransferRecord`、`BatchTransferRecord`：FFI 记录转换。

## 被依赖方

- `PandaSSH.Workspace.TransferStore`：默认真实传输源。

## 边界

该实体将 FFI 错误转为 Swift 调用方可处理的结果；不得使用 `try!` 或无记录的 `try?` 把正常的远端/存储失败变成崩溃或空状态。

