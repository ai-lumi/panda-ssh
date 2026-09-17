## Why

现有覆盖率脚本只检查两条命令是否存在，不能证明生成的报告实际包含会话、传输、TOFU、持久化、日志、遥测、工作区和终端状态机。此前把低覆盖率直接归因于 LLVM profile 丢失，证据不足；门禁应验证产物本身，而不是固化工具行为假设。

FFI 首轮拆分也留下两个边界缺口：批量传输和任务聚合仍由根模块直接装配，领域模块通过根模块私有重导出访问 sibling helper。与此同时，多个单元测试并行读写同一进程级注册表和计数器，削弱覆盖率结果的可重复性。

## What Changes

- 将单文件传输、批量传输和任务聚合收口到同一 `ffi_transfers` 模块树；根模块只保留公共装配，不再中转内部 store、传输通知或 runtime helper。
- 为 panda-ffi 单元测试提供统一的全局状态测试锁，串行化会访问 store、传输注册表、工作区、遥测或日志全局状态的用例。
- 覆盖率门禁清理旧 profile、生成可检查的 core/FFI 报告，先确认所有必需业务 FFI 文件都出现在产物中，再判定 lines/regions 95% 门槛。
- 在开发文档中将该脚本作为 Rust 覆盖率标准入口，并明确 iOS 本地编译验证使用 `CODE_SIGNING_ALLOWED=NO`。
- 清理 panda-ffi 测试中的未使用变量和导入，保持警告为零。

## Non-goals

- 不改变 FFI API、业务行为、覆盖率阈值、持久化格式或 Cargo 依赖。
- 不新增 CI、发布、签名或设备安装行为。

## Impact

- 调整 `crates/panda-ffi` 内部模块装配、测试支持代码和 fake-server 测试锁；公共导出保持不变。
- 更新本地覆盖率脚本、shell 契约测试、README 与 FFI bridge 规格。
