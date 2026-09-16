## ADDED Requirements

### Requirement: 可重复的 Rust 覆盖率门禁

仓库 SHALL 提供单一脚本作为 Rust 覆盖率门禁入口。脚本 MUST 清理旧 LLVM profile，MUST 分别对 `panda-core` 与 `panda-ffi` 测试目标判定 lines 与 regions 均不低于 95%。脚本 MAY 仅排除无状态的 `ffi_adapter`，MUST NOT 排除任何业务 FFI 模块。

#### Scenario: 全新 profile 下执行门禁

- **WHEN** 开发者在仓库根目录运行覆盖率门禁脚本
- **THEN** 旧 profile 不影响结果，core 与 FFI 均分别按 95% lines/regions 阈值返回状态

#### Scenario: 业务 FFI 保持在统计中

- **WHEN** 脚本配置文件级排除
- **THEN** 仅 `ffi_adapter` 被排除，会话、传输、TOFU、持久化、日志、遥测、工作区和终端状态机继续计入统计
