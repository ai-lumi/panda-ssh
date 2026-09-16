## Why

FFI fake-server 测试的 LLVM profile 必须按 `panda-core` 与 `panda-ffi` 分组采集。直接运行 workspace 覆盖率命令会在当前工具链下丢失 FFI profile，产生错误的低覆盖率结果，容易误判门禁。iOS 本地构建也应明确使用无签名验证，避免开发团队配置成为代码验证阻塞。

## What Changes

- 新增受 shell 契约测试保护的 Rust 覆盖率门禁脚本：清理旧 profile、按 core/FFI 分组采集，并汇总判定 lines/regions 95% 门槛。
- 在开发文档中将该脚本作为 Rust 覆盖率标准入口，并明确 iOS 本地编译验证使用 `CODE_SIGNING_ALLOWED=NO`。
- 清理 panda-ffi 测试中的未使用变量和导入，保持警告为零。

## Non-goals

- 不改变 FFI API、业务行为、覆盖率阈值或 Cargo 依赖。
- 不新增 CI、发布、签名或设备安装行为。

## Impact

- 新增本地脚本及其 shell 契约测试；更新 README 与 FFI bridge 规格。
- Rust 测试源码仅进行无行为的编译警告清理。
