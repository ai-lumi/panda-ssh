## Context

FFI 根模块同时承担导出声明和多种有状态实现，导致测试按文件汇总时无法辨别覆盖率责任。现有导出是 Swift 的稳定 ABI 契约，重构必须保持它们不变。

## Decisions

### 决策 1：按状态和资源所有权拆分

拆分为 `ffi_store`、`ffi_sessions`、`ffi_transfers`、`ffi_telemetry`、`ffi_workspace` 与 `ffi_adapter`。模块归属以是否拥有状态、异步资源、持久化副作用或错误策略为准，而非以导出数量为准。

### 决策 2：根模块只作公共装配

`lib.rs` 保留 `uniffi::setup_scaffolding!()`、共享 Record/Enum/Error、模块声明和 `pub use`。所有重导出的函数名称和签名保持不变，以保证 Swift 生成绑定与调用点无需迁移。

### 决策 3：覆盖率豁免最小化

仅 `ffi_adapter` 可以使用文件级排除；模块不得访问 runtime、store、会话/任务注册表、网络、文件系统或包含错误分类策略。其它模块全部纳入 lines/regions 门禁。

### 决策 4：测试 profile 分组生成

使用 `cargo llvm-cov --no-cfg-coverage`。core 与 FFI 测试目标分组完成后再报告；`cfg(coverage)` 已验证会阻塞 FFI fake-server 测试，不能作为门禁模式。

## Risks and mitigations

- UniFFI 宏扫描遗漏子模块导出：每批迁移后运行路径/会话契约测试和 `apple/Scripts/build-rust.sh`。
- 循环依赖：共享类型暂留根模块，领域模块通过 `crate::` 引用；迁移前搜索所有调用边。
- 测试全局状态泄漏：每个启动后台任务的测试显式取消并等待终态。
- 覆盖率被豁免滥用：模块边界审查禁止业务模块依赖 `ffi_adapter` 作为状态入口。
