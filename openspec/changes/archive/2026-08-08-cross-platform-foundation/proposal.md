## Why

产品定位为「Rust 核心 + 原生 UI」：当前阶段需要稳定支撑 macOS 与 iPadOS 双端（SwiftUI 共享源码），同时为未来 Linux（GTK4）与 Windows 复用同一 Rust 核心留出清晰边界。当前代码已基本符合该架构（`panda-core` 纯逻辑、`panda-ffi` 走 uniffi、Swift 侧只做 UI），本变更把这些约束固化为可验证的规格与设计，防止后续改动破坏边界。

## What Changes

- 明确并验证 macOS 与 iPadOS 双端共享 SwiftUI 源码 + 同一 Rust 核心的架构约束。
- 固化 Rust 核心与 UI 的边界：业务逻辑只在 `panda-core`，UI 只通过 uniffi FFI 调用。
- 固化 FFI 契约：同步导出、简单数据类型、不暴露平台特有类型。
- 固化「核心平台无关」约束：`panda-core` 不得依赖 Apple 平台 API，为未来 Linux/Windows 复用留出空间。
- 补充文档（README/AGENTS.md 已描述架构，本变更以规格形式落地并验证构建流程）。

## Non-Goals

- 本变更不实现 Linux/Windows 客户端（明确为未来版本，架构预留即可）。
- 本变更不引入 GTK4 或任何跨平台 UI 框架。
- 本变更不改变双端的运行时功能（纯架构约束与验证）。
- 本变更不处理 iCloud 配置同步（另立变更）。

## Capabilities

### New Capabilities

- `platform`: 双平台支持、Rust 核心与 UI 边界、FFI 契约稳定性与未来平台可扩展性的架构约束。

### Modified Capabilities

None.

## Impact

- macOS 与 iPadOS 双端：双端继续共享 SwiftUI 源码与同一 xcframework，构建流程（`build-rust.sh` → `xcodegen` → `xcodebuild`）作为验证门禁。
- Rust 核心（`crates/panda-core`）：确认无平台依赖（仅 std + 纯 Rust 生态 crate），为 Linux/Windows 复用提供前提。
- FFI（`crates/panda-ffi`）：维持同步导出与全局 runtime 约定；新增类型保持简单值类型（Record/Enum/Optional），不引入平台类型。
- Swift UI：仅通过生成的 uniffi 绑定调用，不直接触碰 Rust 业务逻辑。
- 测试：以构建脚本 + `cargo test` + 双端 `xcodebuild` 作为架构约束的自动验证。
