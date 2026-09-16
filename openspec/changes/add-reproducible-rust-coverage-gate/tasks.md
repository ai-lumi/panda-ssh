## 1. 契约与测试（Red）

- [ ] 1.1 新增 shell 契约测试，先验证覆盖率脚本尚不存在时失败；覆盖清理、core/FFI 分组、无重跑汇总、唯一排除和双阈值。

## 2. 实现（Green）

- [ ] 2.1 新增覆盖率门禁脚本，使 1.1 通过；脚本只操作 Cargo 覆盖率产物与本地测试进程。
- [ ] 2.2 将标准 Rust 覆盖率入口和无签名 iOS 编译验证更新至 README。
- [ ] 2.3 移除 `ffi_workspace` 测试未使用变量与 `task_aggregation_ffi` 未使用导入，不改变断言或行为。

## 3. 验证与归档

- [ ] 3.1 运行 shell 契约测试、`cargo test --workspace` 与新覆盖率脚本；要求 lines/regions 均不低于 95%。
- [ ] 3.2 执行 `build-rust.sh` → `xcodegen` → macOS 构建及无签名 iOS 构建，确认生成绑定和双端编译。
- [ ] 3.3 合并 spec delta，严格校验并归档变更。
