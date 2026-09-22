## Context

见 [proposal.md](proposal.md)。`scripts/verify-rust-coverage.sh` 已对 `panda-ffi` 单独执行 `cargo llvm-cov --lib --tests`，并要求 `lib.rs`、runtime、会话、存储、遥测、传输、工作区、批量传输和任务聚合模块均出现在报告中。唯一允许排除的是无状态纯值适配器 `ffi_adapter.rs`。现有测试分布在模块内单元测试和 `crates/panda-ffi/tests/` 的 fake-server 集成测试中；真实 SSH/SFTP、系统钥匙串与外部网络不应成为测试依赖。

## Goals / Non-Goals

**Goals:**

- 为业务 FFI 模块建立由覆盖率报告驱动的缺口清单，并以可复现命令确认包级及列明生产文件的 lines 均达到 95%；raw regions 仅用于定位补测候选。
- 让新增用例验证 FFI 可观察契约：值/错误映射、状态转换、无效句柄与任务操作、以及存储失败路径。
- 保持测试隔离、并发安全及对临时目录和 fake 服务的明确清理。

**Non-Goals:**

- 不将覆盖率阈值下调、扩大排除文件范围，或将业务代码搬入 `ffi_adapter.rs`。
- 不变更 UniFFI 导出、生产业务规则、凭据存储模型或 Swift 调用路径。
- 不追求逐行 100% 覆盖；95% 门禁是本变更的验收下限，无法由稳定 fake 验证的依赖分支应以最小可审查抽象处理，而非静默豁免。

## Decisions

### D1：报告先行，按模块补测

先执行既有 `scripts/verify-rust-coverage.sh` 并保留 `panda-ffi.json` 中的未覆盖 lines/regions 作为测试设计输入。门禁检查 FFI 包级 lines 及 `lib.rs`、`ffi_runtime.rs`、`ffi_sessions.rs`、`ffi_store.rs`、`ffi_telemetry.rs`、`ffi_transfers.rs`、`ffi_workspace.rs`、`batch_transfer.rs` 与 `task_aggregation.rs` 的生产 lines 均不低于 95%。每个列明模块的导出 API 必须有成功、可观察错误和边界结果的契约测试。raw regions 只用于定位补测候选，不作为包级或逐文件通过条件。`ffi_adapter.rs` 仍是唯一可排除的纯值适配器；独立的 `cfg(test)` 测试源码（包括 `test_support.rs`）不属于业务 FFI 的逐文件门禁对象，也不得混入业务实现文件的统计域。

替代方案是一次性为所有导出增加端到端测试。该方案难以定位失败、会重复覆盖 core 行为且容易引入真实网络依赖，故不采用。

### D2：测试 FFI 边界，不重复测试 core

模块内单元测试验证纯 FFI 决策（错误转换、记录转换、状态机与 registry 行为）；跨模块的导出流程使用既有 `test_support`、临时 store 与 fake SSH/SFTP 服务。每个补测点必须覆盖正常、意外和边界三类场景，且断言结构化结果而非错误文案。

替代方案是仅以 `cargo llvm-cov` 的数字作为测试目标。该方案可能覆盖无意义路径而遗漏契约断言，故不采用。

### D3：可测试性改动须最小且不扩大生产接口

若测试无法确定性驱动某个分支，只允许在 crate 私有范围补充测试夹具、注入点或状态观察；先写失败测试，再做最小实现使其通过。不得暴露新的 UniFFI API、不得在 Swift 重复业务逻辑。

替代方案是把分支加入覆盖率忽略规则。它违反现有 `ffi-bridge` 覆盖率责任，故不采用。

### D4：测试源码与生产业务统计域分离

模块内 `#[cfg(test)]` 测试会被 LLVM region 统计为所属业务文件的一部分，其中包括 `assert!`、`matches!` 与派生实现的不可观察 panic/格式化分支。该统计不能代表生产 FFI 行为是否被执行，且新增高质量测试可反而降低业务文件的 regions 百分比。

因此，模块私有测试 SHALL 使用 `#[path]` 引入独立的 `src/tests/` 测试源码；该源码可以访问父模块私有项，但在覆盖率 JSON 中拥有自己的文件名。门禁 SHALL 仅对列明的生产业务源文件执行逐文件 lines 阈值检查，并以 filename regex 排除 `src/tests/` 与 `test_support.rs` 的测试专用源；这些排除不得匹配任一生产业务源文件。测试运行仍 MUST 覆盖并计入生产业务函数，包级 lines 阈值也继续执行。

替代方案是继续将测试源码内联并接受 region 指标失真。该方案会把测试宏的防御路径误当作业务实现分支，无法满足“业务 FFI 文件”这一验收定义，故不采用。

### D5：逐文件 regions 不作为可观测 FFI 契约代理

LLVM 会为 `async` 状态机、`map`/`ok_or_else` 闭包和锁中毒恢复生成 region；它们不能逐一对应 Swift 可观察的 FFI 行为。实测表明，在成功、错误和边界调用已被 fake 服务与临时存储执行后，继续补相同契约测试不改变逐文件 regions。

因此，门禁 SHALL 保持 FFI 包级及列明生产业务文件 lines >=95%。raw regions（无论包级或逐文件） SHALL NOT 作为通过条件；其缺口仅作为测试设计线索。脚本 SHALL 对每个列明模块的契约测试清单做存在性检查，确保成功、可观察错误和边界条件不会由汇总数字掩盖。

### D6：门禁脚本是最终验证，不是测试替代

完成每组 TDD 用例后运行针对性的 `cargo test -p panda-ffi`；最终以 `scripts/verify-rust-coverage.sh` 验证报告隔离、必需业务文件存在性、包级 lines 阈值、每个列明业务文件的 lines 阈值及契约测试矩阵。若脚本或其 shell 回归测试需要补强，只能增加对既有门禁契约的断言。

## Risks / Trade-offs

- [Rust 全局 runtime、store 或 registry 使测试相互污染] → 每个测试创建唯一临时目录/句柄并在结束时重置测试状态；并行不安全的场景串行化或收敛到既有 test support。
- [为覆盖私有错误分支而错误地改变公共契约] → 所有生产改动必须先由失败测试证明必要性，并检查 UniFFI 导出清单与 Swift 绑定未改变。
- [覆盖数字波动或报告被旧产物污染] → 只认可脚本清理后生成的独立 JSON；复跑门禁以确认稳定性。
- [排除 regex 误匹配生产源文件] → shell 回归测试显式验证仅测试目录与 `test_support.rs` 被排除，并逐项验证全部业务源文件仍出现在报告中。
- [fake 服务与真实协议行为偏离] → fake 仅验证 FFI 映射与生命周期；协议行为继续由 `panda-core` 的测试承担，避免把 fake 当作网络兼容性证明。

## Migration Plan

1. 先记录当前门禁报告与未覆盖分支，不改变生产行为。
2. 按模块执行 red-green-refactor，保持每次改动可独立运行测试。
3. 运行完整 Rust 测试与覆盖率门禁；若 FFI 签名意外发生变化，停止并按 FFI/Swift 构建流程单独评审。
4. 回滚只需撤回新增测试或测试专用私有辅助代码；没有数据迁移、配置迁移或外部部署。
