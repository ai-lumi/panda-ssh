## 1. 基线与契约

- [x] 1.1 记录当前导出符号、Swift 绑定调用点和领域归属；将每项标记为迁移、保留或验证。
- [x] 1.2 用现有与新增 Rust 测试覆盖每个迁移领域的正常、失败与边界路径。
- [x] 1.3 用 `--no-cfg-coverage` 分组生成可重复覆盖率基线。

## 2. 模块拆分

- [x] 2.1 先拆分 `ffi_adapter`：路径纯值转发；保持导出名称不变并通过跨 FFI 路径契约测试。
- [x] 2.2 拆分 `ffi_store`：配置、凭据、分组、片段、导入导出；不改变持久化或凭据边界。
- [x] 2.3 拆分 `ffi_sessions`：Shell/SFTP 句柄和精确关闭；测试同主机隔离、重复关闭与无效句柄。
- [x] 2.4 拆分 `ffi_transfers`：单文件和批量传输的注册表、调度和状态转换；测试取消、暂停、重试、冲突与收尾。
- [x] 2.5 拆分 `ffi_telemetry`：遥测、生命周期和日志；测试敏感信息不泄露及释放后事件可查询。
- [x] 2.6 拆分 `ffi_workspace`：工作区和终端状态机；测试标签关闭、确认、重试、陈旧代次与幂等性。

## 3. 门禁与兼容性

- [x] 3.1 搜索并确认无状态 `ffi_adapter` 不访问 runtime、store、会话/任务注册表、网络或文件系统。
- [x] 3.2 运行 `cargo test --workspace` 与领域测试全绿。
- [x] 3.3 运行 `apple/Scripts/build-rust.sh`，验证 UniFFI 绑定生成和既有 Swift API 兼容。
- [x] 3.4 按 core 与 FFI 测试目标分组采集 profile，再以文件级仅排除 `ffi_adapter` 的方式运行 Rust lines/regions ≥ 95% 门禁；业务 FFI 模块必须纳入。
