## 1. 交互式 shell 通道（Rust 核心）

- [x] 1.1 先写测试：`SshSession` 打开 session channel 后，`ShellSession` 能写入输入并读取远端输出（用 fake channel 抽象，不连真实服务器）。
- [x] 1.2 实现 `ShellSession`（`panda-core::ssh`）：open/write/read/close 与带缓冲读写队列。
- [x] 1.3 先写测试：`ShellSession` 关闭后再次读写返回明确错误。
- [x] 1.4 FFI 新增 `shell_open`/`shell_write`/`shell_read`/`shell_close`，全部同步导出、跑在全局 tokio runtime；先写测试覆盖句柄生命周期与未初始化 store 报错。

## 2. 标签页工作区 UI（Swift，macOS/iPadOS 共享源码）

- [x] 2.1 先写测试：`WorkspaceTab` 模型的新建/切换/关闭状态机（增删、选中索引越界保护）。
- [x] 2.1a 先写测试：同一主机重复打开总是新建标签（不去重），同主机标签标题按序号消歧（「web-prod」「web-prod (2)」），关闭中间标签后序号重算。
- [x] 2.2 实现 `WorkspaceTab` 模型与工作区视图容器（标签栏 + 内容区分发），含标题消歧逻辑。
- [x] 2.3 实现终端标签页：`shell_open` 会话包装对象 + SwiftTerm 接线（读写字节流）；未存钥匙串的密码按标签页独立持有，关闭即销毁。
- [x] 2.4 实现 SFTP 标签页：左本地、右远程双栏骨架与目录切换。
- [x] 2.5 标签页关闭时释放会话（close → disconnect）；连接失败显示错误并提供重试；同一主机的并发连接只触发一次指纹确认（其余等待结果）。

## 3. 验证

- [x] 3.1 `cargo test` 全绿。
- [x] 3.2 macOS 构建：`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build`。
- [x] 3.3 双端手工验证：打开/切换/关闭多个终端与 SFTP 标签页互不影响。

## 4. 质量门禁

- [x] 4.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 4.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。
