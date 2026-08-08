## 1. 架构约束审计（Rust 核心）

- [x] 1.1 审计 `panda-core` 依赖与代码：确认无 Apple 平台 API（std + 纯 Rust 生态 crate），记录结论。
- [x] 1.2 审计 `panda-ffi`：确认全部导出同步、类型为简单值类型、密钥材料不落盘；记录结论。
- [x] 1.3 先写测试：核心 crate 在非 Apple 目标上可 `cargo check`（如 `cargo check --target x86_64-unknown-linux-gnu` 若本机可用），验证平台无关性。（已执行；失败点为 russh 的 aws-lc-sys 需 Linux 交叉 C 工具链，属环境限制，结论与失败点已记录于 design.md「审计结论」）

## 2. Swift/UI 边界（双端共享源码）

- [x] 2.1 审计 `apple/PandaSSH`：确认业务逻辑不绕过 FFI；仅文件选择器、钥匙串等平台服务用平台分支；记录结论。
- [x] 2.2 补充平台条件编译规范文档（放入 AGENTS.md「代码结构」节）。

## 3. 构建门禁与验证

- [x] 3.1 完整跑通 `build-rust.sh`（补 `crates/panda-ffi/src/bin/uniffi-bindgen`，修复已知脚本缺陷）→ `xcodegen` → macOS 与 iPadOS 双端 `xcodebuild`。（bindgen bin 已存在，脚本无缺陷，全链一次通过）
- [x] 3.2 `cargo test` 全绿。
- [x] 3.3 将架构约束（分层边界、FFI 契约、依赖平台无关）写入 AGENTS.md，形成评审检查清单。

## 4. 质量门禁

- [x] 4.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。（本变更为审计/工具链/文档，无新增行为代码；验证点即构建链正常流程 + 非 Apple 目标边界；既有测试已覆盖正常/意外/边界三类——config/hostkey 单测含空文件、缺目录、非法 TOML，FFI 含 not_initialized/broken_store 错误路径）
- [x] 4.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。（lines 98.77%、regions 97.41%）
