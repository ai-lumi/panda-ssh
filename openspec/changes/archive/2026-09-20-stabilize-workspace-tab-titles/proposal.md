## Why

同一主机的页签标题目前在读取列表时按剩余页签重新编号。关闭较早的页签会改变仍打开页签的标题，破坏用户对页签身份的连续认知。

## What Changes

- 在创建页签时确定其同主机标题及消歧序号，并作为页签状态保存。
- 关闭、重排、分组或同步页签列表时保留仍打开页签的既有标题。
- 新建页签为同一主机选择一个不与当前打开页签冲突的标题；已释放的序号可被后续新建页签复用。

## Non-goals

- 不改变终端或 SFTP 会话的创建、关闭与连接状态规则。
- 不新增用户可编辑的页签标题，也不持久化跨应用重启的工作区页签。
- 不修改 macOS 与 iPadOS 的页签栏布局或交互方式。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`: 修改同主机页签标题消歧规则，使标题在页签生命周期内保持稳定。

## Impact

- 影响 `crates/panda-core` 中标题分配算法及其单元测试。
- 影响 `crates/panda-ffi` 中工作区内存状态和 `workspace_tab_list` FFI 返回的标题。
- macOS 与 iPadOS 共用同一 Rust 状态和 FFI，因此两端获得一致的稳定标题行为，无需平台分支或新增依赖。
