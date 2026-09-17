# 验证记录：add-reproducible-rust-coverage-gate

## TDD 契约

- Red：`scripts/tests/test_ffi_module_boundaries.sh` 在实现前以“缺少独立 runtime 模块”失败。
- Red：`scripts/tests/test_verify_rust_coverage.sh` 在实现前以“缺少覆盖率门禁契约：--exclude-from-report panda-core”失败。
- Green：两条 shell 契约测试均通过；覆盖率测试还以 mock cargo 验证旧报告残留、业务文件缺失、统计域交叉、adapter 未排除和 cargo 失败五类失败路径。

## Rust 与并发隔离

- `cargo check -p panda-ffi --all-targets`：通过，零个未使用变量/导入 warning。
- `cargo test -p panda-ffi --lib`：85/85 通过。
- `cargo test -p panda-ffi --test ffi_fake_server`：67/67 通过；沙箱内禁止绑定回环端口，获准在本机环境重跑后通过。
- `cargo test --workspace`：通过；真实外部 SSH 服务器用例按设计保持 ignored，doc tests 通过。
- 锁审计：fake-server 的 67 个测试全部持其进程锁；store、transfer、workspace、telemetry/logger 的进程级全局状态测试全部复用 `cfg(test)` 统一锁，纯值或局部状态测试不持锁。

## 覆盖率门禁

执行 `bash scripts/verify-rust-coverage.sh`，cargo-llvm-cov 0.8.7 返回 0：

| 报告 | Lines | Regions |
| --- | ---: | ---: |
| panda-core | 95.6522%（6226/6509） | 95.0609%（11548/12148） |
| panda-ffi | 97.6077%（3468/3553） | 95.7557%（5911/6173） |

FFI JSON 报告包含 `lib.rs`、`ffi_runtime.rs`、`ffi_sessions.rs`、`ffi_store.rs`、`ffi_telemetry.rs`、`ffi_transfers.rs`、`ffi_workspace.rs`、`batch_transfer.rs`、`task_aggregation.rs`；不包含 `ffi_adapter.rs` 或 `panda-core` 文件。core 报告不包含 `panda-ffi` 文件。

## UniFFI 与 Apple 构建

1. `apple/Scripts/build-rust.sh`：4 个 Apple 目标 release 构建、Swift 绑定生成和 xcframework 打包通过。
2. 重构前后归一化比较：202 条 `uniffi_panda_ffi_*` C 声明集合相同；410 条 Swift `public` 声明集合相同。原始差异是声明顺序及 9 个迁移函数的 checksum。
3. checksum 包含完整 Rust `module_path!()`，批量传输 8 个函数和任务聚合 1 个函数的数值按预期变化；因此已成对刷新库与 wrapper，不声明新库兼容旧 wrapper。
4. `xcodegen`：通过。
5. `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -configuration Debug build`：`BUILD SUCCEEDED`。
6. `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`：`BUILD SUCCEEDED`。

## OpenSpec

- `openspec validate add-reproducible-rust-coverage-gate --strict`：通过（归档前）。
