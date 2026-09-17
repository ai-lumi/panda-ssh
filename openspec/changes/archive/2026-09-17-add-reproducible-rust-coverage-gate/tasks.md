## 1. 契约与测试（Red）

- [x] 1.1 新增 FFI 模块边界契约测试，先验证根模块仍直接装配批量传输/任务聚合、仍中转私有 helper 时失败。
- [x] 1.2 更新覆盖率 shell 契约测试，先验证当前脚本未生成可检查报告、未核对必需业务 FFI 文件时失败。
- [x] 1.3 记录所有访问进程级全局状态的 panda-ffi 单元测试和 fake-server 测试，定义统一锁边界。

## 2. 实现（Green）

- [x] 2.1 将批量传输和任务聚合收口为 `ffi_transfers` 子模块，保持根级公共重导出与 UniFFI 契约不变。
- [x] 2.2 新增内部 runtime 模块，并让 sessions/transfers/telemetry 直接依赖 runtime/store 内部模块；移除根模块私有 helper 中转。
- [x] 2.3 新增 `cfg(test)` 全局测试锁，串行化 store、transfer、workspace、telemetry/logger 单元测试；补齐 fake-server 遗漏锁。
- [x] 2.4 重写覆盖率门禁：清理旧产物、生成报告、核对必需业务 FFI 文件并判定 lines/regions 95%。
- [x] 2.5 将标准 Rust 覆盖率入口和无签名 iOS 编译验证保持在 README。
- [x] 2.6 保持未使用变量和导入为零，不改变断言或业务行为。

## 3. 验证与归档

- [x] 3.1 运行模块边界与覆盖率 shell 契约测试、panda-ffi scoped 测试及 `cargo test --workspace`。
- [x] 3.2 实际运行覆盖率脚本；要求必需业务 FFI 文件全部出现，lines/regions 均不低于 95%。
- [x] 3.3 比较重构前后 UniFFI 导出、C 原型与 Swift 公共声明集合。
- [x] 3.4 执行 `build-rust.sh` → `xcodegen` → macOS 构建及无签名 iOS 构建。
- [x] 3.5 合并 spec delta，严格校验并归档变更。
