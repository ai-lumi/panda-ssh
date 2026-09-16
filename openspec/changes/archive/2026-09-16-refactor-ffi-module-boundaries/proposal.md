## Why

`crates/panda-ffi/src/lib.rs` 目前超过四千行，混合配置/凭据、SSH 与 SFTP 会话所有权、传输调度、遥测日志、工作区和终端状态机。当前文件级覆盖率无法说明缺口归属，也不能安全地区分纯值适配器与业务生命周期逻辑。

已验证 `panda-core` 覆盖率达到 lines 96.36%、regions 95.82%，而 FFI 根模块仍是总门禁的主要缺口。直接排除整个 FFI crate 或 `lib.rs` 会同时豁免连接、传输和状态机，违反现有测试门禁与分层要求。

## What Changes

- 按状态与资源所有权边界拆分 `panda-ffi/src/lib.rs`：store、会话、传输、遥测、工作区/终端与纯适配器分别成模块。
- `lib.rs` 只保留 UniFFI 初始化、共享 FFI 类型、模块声明与重导出；既有导出名称、参数、返回类型和同步调用语义不变。
- 只有无状态、无资源所有权、无错误策略的纯值适配器可放入 `ffi_adapter` 并在覆盖率报告中单独审查；会话、传输、TOFU、持久化、日志与状态机必须继续计入门禁。
- 稳定化 FFI fake-server 测试的后台任务收尾，按测试目标分组收集 LLVM profile，避免覆盖率采集被长组或残留任务污染。

## Non-goals

- 不新增或删除任何 UniFFI API，不改 Swift 调用点或生成绑定。
- 不改变 SSH/SFTP、传输、TOFU、凭据、日志或工作区的业务规则。
- 不通过排除整个 `panda-ffi` crate 或混合业务模块降低覆盖率门槛。
- 不新增依赖、不改全局 Tokio runtime，也不改变密码和口令只作瞬态参数传递的安全边界。

## Impact

- Rust：`crates/panda-ffi/src/lib.rs` 与新建的领域模块；测试按领域补齐或迁移。
- Swift：编译验证生成绑定与既有调用保持兼容，不应有源代码行为改动。
- OpenSpec：修改 `ffi-bridge`，加入模块边界和覆盖率责任要求。
- 验证：领域测试、现有 fake-server 测试、UniFFI 绑定生成、Rust lines/regions 95% 门禁。
