# Proposal: 传输任务暂停与继续

## Problem

当前传输任务在运行中只有「取消」操作，没有「暂停/继续」。用户无法临时中断一个正在进行的大文件传输去处理其他任务，必须取消后重新传输。

## Goal

为单个传输任务提供暂停与继续能力：

- 运行中的任务可以暂停，暂停期间保留已传输进度、不释放并发槽位、不关闭 SSH/SFTP 连接。
- 已暂停的任务可以继续，从暂停点恢复读写。
- 排队中的任务也可以被暂停；被暂停的排队任务在恢复前不会获取并发许可证。
- UI 上每个非终态任务提供暂停/继续按钮，并展示 `paused` 状态。

## Scope

- `panda-core`：`SftpClient.upload_with_cancel` / `download_with_cancel` 增加暂停/继续能力（保持旧 API 兼容）。
- `panda-ffi`：新增 `transfer_pause`、`transfer_resume`；任务状态机增加 `Paused`。
- Swift `TransferStore` / `TransferPanelView`：暴露暂停/继续操作与状态。
- OpenSpec `transfers/spec.md`：新增暂停/继续需求。
- 测试：Rust 核心 + FFI 测试、Swift `TransferStore` 测试。

## Non-Goals

- 本次不实现跨 App 重启的断点续传（持久化 offset）。
- 不改变现有取消、重试语义。

## Success Criteria

1. `cargo test` 与 Swift 测试全绿。
2. 运行中任务暂停后状态变为 `paused`，进度停止增长。
3. 继续后任务恢复为 `running`，进度继续增长直至完成。
4. 排队任务暂停后不会提前占用 3 个并发槽位之一。
