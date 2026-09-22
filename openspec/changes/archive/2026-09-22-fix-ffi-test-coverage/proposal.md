## Why

Rust 覆盖率门禁已将 `panda-ffi` 的业务模块纳入独立统计域，但现有测试未能充分执行所有业务分支，导致 FFI 包无法稳定满足可验证的 95% 门禁。另一方面，LLVM raw regions 会计入 async 状态机、闭包和测试宏生成的不可观察分支；在测试源码与生产源码分离后，它不能稳定代表生产 FFI 契约的覆盖程度。该问题会阻断提交，也会降低 FFI 错误映射、会话生命周期、传输调度及持久化适配的回归发现能力。

## What Changes

- 以覆盖率报告为基线，逐个定位 `panda-ffi` 业务模块中未覆盖的行与分支，并为可观察 FFI 契约补充测试。
- 将 FFI 覆盖率验收从仅检查包汇总值收紧为逐生产业务源文件与可观测契约检查：包级及每个列明业务文件的 lines 均须达到 95%，每个导出业务 API 须覆盖成功、可观察错误与边界结果；LLVM raw regions 仅保留为补测诊断线索，不再作为门禁。
- 按 TDD 为每个缺口先增加失败用例，再以最小实现修正仅为可测试性所必需的测试夹具或依赖注入；不得通过扩大覆盖率排除范围规避门禁。
- 固化 FFI 测试矩阵：每个受影响模块覆盖正常流程、错误/意外流程和边界流程，并使用 fake SSH/SFTP 服务或临时存储隔离外部依赖。
- 维持既有 UniFFI 导出名称、参数、返回类型、同步调用外观，以及 macOS/iPadOS 共用的 Swift 契约。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `ffi-bridge`：将业务 FFI 覆盖率门禁收紧为包级及逐列明业务源文件 lines 不低于 95%，并对导出 FFI 契约执行成功、错误和边界结果检查；raw regions 仅用于诊断。

## Impact

- 受影响代码：`crates/panda-ffi/src/` 的业务模块、`crates/panda-ffi/tests/` 测试夹具与集成测试，必要时 `scripts/verify-rust-coverage.sh` 的验证性检查。
- 不修改 `panda-core` 领域行为、UniFFI 公共接口、Swift 生产代码或 macOS/iPadOS 界面行为；两端仅通过现有 Rust FFI 契约获得相同的回归保障。
- 不新增运行时依赖、网络服务或持久化格式；测试使用现有 fake 服务和临时目录。

## Non-goals

- 不以 `--ignore-filename-regex` 或其他排除规则将业务 FFI 模块移出覆盖率统计域；测试专用源码可被排除，但其执行的生产业务模块仍须逐文件达标。
- 不借此重构 FFI 模块边界、扩展产品功能或改变 SSH/SFTP 协议语义。
- 不要求真实 SSH 服务器、系统钥匙串或外部网络作为测试前提。
