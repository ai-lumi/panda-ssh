## Context

见 proposal.md。Rust 以字符串精确匹配页签 ID；Swift 的 UUID 展示格式会改变字母大小写。`WorkspaceStore` 是这两个表示之间的现有适配边界。

## Goals / Non-Goals

恢复已规格化的关闭确认和页签移除；不引入新的业务状态机、平台分支或 FFI API。

## Decisions

1. 页签 ID 传入 FFI 时统一小写，读取记录时按 UUID 值比较。不修改 Rust ID 格式或向全部导出函数添加兼容逻辑，避免扩大本次修改范围。
2. `requestClose` 负责既有确认门控；`close` 负责执行关闭。执行关闭时先同步移除 Rust 页签，再释放本地注册会话，避免状态上报或延迟视图回调重新保留该页签。
3. XCTest 使用真实工作区 FFI 和 MockShellConnection，不建立网络连接；每个工作区用例显式重置 FFI 全局状态，避免不同测试互相污染。

## Risks / Trade-offs

- [生命周期风险] → 验证确认前无断开、取消后保留、确认后精确释放，以及重复关闭幂等。
- [现有未提交接口变化] → 只把相关测试从旧 checker 注入改为实际连接状态上报，不恢复旧生产接口。
- [系统弹窗呈现] → 模型测试验证触发状态；双端构建检查视图装配，真实窗口交互单独标记验收范围。

## 影响映射与评审

| 依赖组 | 处理 | 验证 |
| --- | --- | --- |
| WorkspaceStore 状态上报、状态读取、选择、关闭 | 修改 ID 适配与执行顺序 | 真实 FFI 往返测试 |
| 页签 X、失败页关闭、预连接取消 | 保留现有回调 | 请求/执行关闭测试及调用检查 |
| 单项/批量确认与取消 | 保留状态语义 | 正常、取消、重复操作测试 |
| TerminalSessionStore/SftpSessionStore 注册会话 | 保留精确释放 | 同主机双会话测试 |
| Rust/FFI API、传输队列 | 仅验证 | cargo test、既有传输测试 |
| WorkspaceStoreTests/WorkspaceStoreReconnectTests | 适配现有接口及隔离全局状态 | Swift XCTest |

评审结论：修改落在 Swift 表示适配和 UI 生命周期胶水层，保留业务及 FFI 契约，不修改协议、持久化或架构；先获得失败回归测试，再修改实现。
