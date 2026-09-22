## MODIFIED Requirements

### Requirement: FFI 模块边界与覆盖率责任

FFI 实现 SHALL 将无状态纯值适配器与拥有业务状态、资源生命周期、持久化副作用或错误策略的实现分离。只有纯值适配器模块 MAY 被覆盖率文件级排除；会话、传输、TOFU、凭据、日志、遥测、工作区和终端状态机 MUST 继续计入 Rust 包级 lines 覆盖率门禁。`lib.rs`、`ffi_runtime.rs`、`ffi_sessions.rs`、`ffi_store.rs`、`ffi_telemetry.rs`、`ffi_transfers.rs`、`ffi_workspace.rs`、`batch_transfer.rs` 与 `task_aggregation.rs` SHALL 分别在覆盖率产物中出现，且每个生产业务文件的 lines MUST 不低于 95%。每个业务模块的导出 API MUST 具有成功、可观察错误和边界结果的契约测试。模块私有的 `cfg(test)` 测试 SHALL 位于独立测试源文件；测试源与 `test_support.rs` 不属于逐文件业务 FFI 阈值，且 MUST NOT 混入业务实现文件的 region 统计。LLVM raw regions（包级或逐文件）仅可作为补测诊断线索，不得作为门禁。单文件传输、批量传输和任务聚合 SHALL 由同一内部传输模块树拥有；FFI 根模块 SHALL 只装配公共导出和共享 FFI 类型，不得中转领域模块的私有 helper。模块拆分 MUST NOT 改变既有 UniFFI 导出名称、参数、返回类型或同步调用外观。

#### Scenario: 传输域依赖闭合

- **WHEN** 检查 FFI 内部模块依赖
- **THEN** 单文件传输、批量传输和任务聚合属于同一传输模块树，批量传输可直接使用域内通知能力，根模块不暴露私有中转别名

#### Scenario: 纯适配器可独立审查

- **WHEN** 覆盖率配置排除 FFI 纯适配器模块
- **THEN** 被排除模块仅包含无状态值转换或 core 函数转发，且不访问 runtime、store、会话/任务注册表、网络或文件系统

#### Scenario: 业务 FFI 仍受逐文件门禁约束

- **WHEN** 运行 Rust 覆盖率门禁
- **THEN** `lib.rs`、`ffi_runtime.rs`、`ffi_sessions.rs`、`ffi_store.rs`、`ffi_telemetry.rs`、`ffi_transfers.rs`、`ffi_workspace.rs`、`batch_transfer.rs` 与 `task_aggregation.rs` 均出现在覆盖率产物中，且每个文件及 FFI 包级的 lines MUST 不低于 95%；`cfg(test)` 测试辅助源文件不计入该逐文件阈值；raw regions 不得单独阻断门禁

#### Scenario: 测试源码不稀释生产文件指标

- **WHEN** FFI 模块的私有单元测试被编译并运行
- **THEN** 测试源码的 assertion、格式化及 panic 防御 region 不会计入列明生产业务文件的逐文件覆盖率；测试执行的生产函数仍计入该生产文件的覆盖率

#### Scenario: 契约测试不能被汇总值掩盖

- **GIVEN** FFI 包的汇总 lines 已达到 95%
- **WHEN** 任一列明业务模块缺少成功、可观察错误或边界结果的契约测试
- **THEN** 覆盖率门禁 MUST 失败并指出该模块及缺少的场景；raw regions（包级或逐文件）仅作为补测线索，不得单独阻断门禁

#### Scenario: 拆分保持 Swift 契约

- **WHEN** FFI 内部模块被拆分后生成 Swift 绑定
- **THEN** 既有 Swift 调用可继续以相同导出名称、参数和返回类型构建及运行

### Requirement: 可重复的 Rust 覆盖率门禁

仓库 SHALL 提供单一脚本作为 Rust 覆盖率门禁入口。脚本 MUST 清理旧 LLVM profile，MUST 生成可检查的覆盖率报告，并 MUST 在判定 `panda-core` 的 lines 与 regions 均不低于 95%、以及 FFI 包级和列明生产业务文件的 lines 均不低于 95% 前确认所有必需业务 FFI 模块都出现在报告中。脚本 MUST 验证每个列明 FFI 业务模块均有成功、可观察错误和边界结果的契约测试。LLVM raw regions（包级或逐文件）仅作为 FFI 补测诊断线索，不得作为 FFI 门禁。脚本 MAY 排除无状态的 `ffi_adapter` 和测试专用源码，MUST NOT 排除任何业务 FFI 模块。

#### Scenario: 全新 profile 下执行门禁

- **WHEN** 开发者在仓库根目录运行覆盖率门禁脚本
- **THEN** 旧 profile 不影响结果，报告来自本次测试执行，`panda-core` 按 95% lines/regions 阈值返回状态，FFI 按包级和逐文件 95% lines 阈值及契约测试矩阵返回状态

#### Scenario: 业务 FFI 保持在统计中

- **WHEN** 脚本配置文件级排除
- **THEN** 仅无状态 `ffi_adapter` 与测试专用源码可被排除；会话、传输、TOFU、持久化、日志、遥测、工作区和终端状态机继续计入 FFI lines 统计

#### Scenario: 汇总值不能掩盖缺失模块

- **GIVEN** FFI 覆盖率报告缺少任一必需业务源文件
- **WHEN** 即使 FFI 包级 lines 已达到 95%
- **THEN** 门禁仍 MUST 失败并指出缺失文件
