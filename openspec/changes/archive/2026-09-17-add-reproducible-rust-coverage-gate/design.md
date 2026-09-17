## Context

`cargo llvm-cov` 的不同调用方式曾产生互相矛盾的汇总结果。仅检查命令文本或预设“workspace 模式会丢失 FFI profile”都不能形成可靠证据。门禁必须检查实际报告中是否存在要求纳入的业务源文件。

首轮 FFI 拆分保持了公共 ABI，但 `batch_transfer`、`task_aggregation` 仍由根模块直接装配，内部 helper 也经根模块中转。模块依赖可以在不改变文件内容和公共重导出的前提下进一步收口。

## Decisions

### 决策 1：传输域形成单一内部模块树

`ffi_transfers` 作为父模块拥有单文件传输、批量传输和任务聚合子模块，并统一对根模块重导出公共项。store 与 runtime 依赖使用明确的内部模块路径，根模块不再充当私有 service locator。

### 决策 2：测试锁只存在于 `cfg(test)` 支持层

所有访问进程级全局状态的 panda-ffi 单元测试共享同一把测试锁。锁不进入生产构建，也不改变运行时并发语义；纯值转换和局部状态测试无需持锁。fake-server 集成测试继续使用其进程内现有锁，并补齐遗漏用例。

### 决策 3：门禁验证产物而非命令文本

脚本显式清理覆盖率产物并生成机器可检查的报告。报告必须列出所有要求纳入的业务 FFI 源文件；任一文件缺失时，即使汇总数字超过阈值也失败。阈值仍由 `cargo llvm-cov` 判定，shell 测试只保护脚本契约，最终验证必须实际执行门禁。

### 决策 4：无签名 iOS 构建仅作为本地代码验证

README 将明确使用 `CODE_SIGNING_ALLOWED=NO` 的 generic iOS Simulator 命令。该命令只验证编译与链接，不代表可安装、真机签名或发布。

## Risks and mitigations

- UniFFI 子模块路径会进入 metadata/checksum：重构后 MUST 通过 `build-rust.sh` 成对刷新库与 Swift wrapper，不允许新库混用旧 wrapper；兼容性比较生成的 C 原型和 Swift 公共声明集合，不比较声明排列顺序或 checksum 数值。
- 全局测试锁嵌套死锁：每个测试只获取一次统一锁，helper 不重复获取；后台任务必须在释放锁前进入终态。
- 覆盖率报告格式变化：脚本只依赖稳定的源文件记录和 cargo-llvm-cov 自身阈值退出码。
