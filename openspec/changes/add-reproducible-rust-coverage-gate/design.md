## Context

`cargo llvm-cov` 的 workspace 单次执行在本项目当前 fake-server 测试布局下不能稳定合并 FFI profile。已有验证证明：先采集 core、再采集 FFI、最后使用 `--no-run` 汇总可得到有效门禁结果。

## Decisions

### 决策 1：脚本显式拥有 profile 生命周期

脚本先使用 `cargo llvm-cov clean --workspace` 清理仅覆盖率目标目录内的旧 profile，再分别独立运行 core 与 FFI 的带阈值门禁。当前 cargo-llvm-cov 不允许 `--no-report` 与 `--no-clean` 组合，跨命令 profile 合并不稳定；分别判定两个 crate 的 lines 与 regions 均不低于 95%，在每个 crate 均纳入统计的前提下，必然蕴含工作区加权总覆盖率不低于 95%。

### 决策 2：用静态 shell 契约测试保护命令顺序

测试断言脚本包含清理、两个独立门禁命令、唯一的 `ffi_adapter` 排除和 95% 双阈值。测试不执行覆盖率本身，避免在单元测试中重复启动 fake server。

### 决策 3：无签名 iOS 构建仅作为本地代码验证

README 将明确使用 `CODE_SIGNING_ALLOWED=NO` 的 generic iOS Simulator 命令。该命令只验证编译与链接，不代表可安装、真机签名或发布。
