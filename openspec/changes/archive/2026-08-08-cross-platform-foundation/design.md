## Context

架构分三层：`panda-core`（纯业务逻辑）、`panda-ffi`（uniffi 绑定，同步导出）、`apple/PandaSSH`（SwiftUI 多平台共享源码，用 SwiftTerm）。README 声明未来 Linux 用 GTK4 复用同一 Rust 核心。当前 `panda-core` 依赖均为纯 Rust 生态（russh、tokio、serde、toml 等），无平台耦合；`panda-ffi` 不落密钥材料，Swift 负责钥匙串。本变更将这些约束显式固化为规格。

## Goals / Non-Goals

**Goals:**

- 双端（macOS 14+ / iPadOS 17+）同一 SwiftUI 源码 + 同一 Rust 核心产物。
- `panda-core` 不含任何 Apple 平台 API，可被未来 Linux/Windows 前端复用。
- FFI 契约稳定：同步导出、简单值类型、全局 tokio runtime（`block_on`），不暴露平台类型。
- 构建流程（`build-rust.sh` → `xcodegen` → `xcodebuild`）作为架构验证门禁。

**Non-Goals:**

- 实现 Linux/Windows 客户端（架构预留即可）。
- 引入 GTK4 或其它跨平台 UI 栈。
- 在本次变更中实现 iCloud 配置同步。

## Decisions

### 分层边界规则

1. 所有业务逻辑（配置、分组、主机密钥、SSH、SFTP、传输、片段）只允许在 `crates/panda-core`。
2. Swift 侧只做 UI 与平台服务（钥匙串、文件选择、iCloud KV、SwiftTerm），业务逻辑一律经 FFI。
3. `crates/panda-core` 的 `Cargo.toml` 依赖清单是「平台无关」的守门点：新增依赖必须跨平台可用（Linux/Windows 可编译），引入 Apple 专属 crate 属违规。

### FFI 契约

- 所有导出函数同步；异步跑在懒初始化的全局 tokio runtime（`block_on`），不得另起 runtime。
- 导出类型为 uniffi 简单值类型（Record/Enum/Optional/String/整数等），不得暴露 `PathBuf` 之外的平台耦合；密钥材料不经过 FFI 落盘。
- `init_store(config_dir)` 的路径由 App 注入（App Group 容器），未来 Linux/Windows 由各自前端注入等价配置目录。

### 双端共享源码约束

`apple/PandaSSH` 为双 target 共享源码，仅在确有必要处用平台条件编译（如文件选择器 `NSOpenPanel` vs `UIDocumentPicker`）；工程结构改动必须改 `apple/project.yml`，不能直接改 `.xcodeproj`。

### 验证

架构约束的自动验证即构建流程：`cargo test`（核心）+ 双端 `xcodebuild` 编译通过 + `build-rust.sh` 产出 xcframework 与 Swift 绑定。

## Risks / Trade-offs

- [新增依赖可能悄悄引入平台耦合] → 以「核心依赖必须跨平台可编译」为评审规则，纳入变更评审检查清单。
- [Swift 侧绕过 FFI 直接实现业务逻辑] → 通过 code review 约定 + 规格约束防范。
- [未来 Linux/Windows 需要不同 FFI 或不同存储根] → `init_store` 已抽象配置目录注入，其余核心逻辑与平台无关。

## Migration Plan

无数据迁移。本变更不改变运行时数据，仅固化约束与补齐验证。

## 审计结论

审计日期：2026-08-06。逐项结论如下。

### panda-core 平台无关性（任务 1.1）——通过

- `crates/panda-core/Cargo.toml` 依赖：tokio、serde、toml、thiserror、russh、russh-sftp、uuid、tracing，全部为跨平台纯 Rust 生态 crate，无 Apple 专属依赖（无 core-foundation / objc / security-framework 等）。
- 源码（config / hostkey / ssh / sftp 四模块）无 `cfg(target_os)` 平台分支，无 Apple 平台 API；唯一的平台 cfg 是测试文件 `tests/fake_server.rs` 里的 `#[cfg(unix)]`（私钥权限位用 `PermissionsExt`，属测试辅助且 Unix 通用，非 Apple 专属）。
- 密钥材料不落盘：TOML 只存 `password_ref` / `passphrase_ref` 引用 key。

### panda-ffi 契约（任务 1.2）——通过

- 全部 `#[uniffi::export]` 函数同步导出，异步经懒初始化全局 tokio runtime `block_on`（`RUNTIME: OnceLock<Runtime>`），无另起 runtime。
- 导出类型均为简单值类型：`HostConfigRecord` / `RemoteFileRecord`（Record，字段为 String/u16/u64/bool/Option）、`AuthMethodEnum`（Enum）、`PandaError`（Error）；密钥路径以 `String` 传递，不暴露 `PathBuf` 等平台耦合类型。
- 密钥材料不经 FFI 落盘：`password` / `passphrase` 仅作调用参数传入（`test_connection` / `sftp_*`），FFI 层无写钥匙串或密钥文件行为。

### 非 Apple 目标编译验证（任务 1.3）——受环境限制，记录失败点

- `rustup target add x86_64-unknown-linux-gnu` 成功（官方源下载停滞，改用 rsproxy.cn 镜像手动下载 rust-std 组件并放入 `~/.rustup/downloads/` 缓存后安装成功）。
- `cargo check --target x86_64-unknown-linux-gnu` **未通过**，失败点：`aws-lc-sys v0.43.0`（依赖链 `russh → aws-lc-rs → aws-lc-sys`）的 build script 需要用 `cc` 为目标平台编译 C 代码，本机（macOS）缺少 Linux 交叉 C 工具链（`x86_64-linux-gnu-gcc` 不存在）。
- 结论：这是**交叉编译环境限制**（macOS 主机无 Linux C 工具链），不是代码的平台耦合；panda-core 自身无 Apple API（见 1.1），在真实 Linux 主机或装有交叉 gcc 的环境中可编译。按变更纪律未改动依赖，未安装系统级交叉工具链，此失败点如实记录。

### Swift/UI 边界（任务 2.1）——通过

- 业务逻辑全部经 FFI/backend 层：主机配置走 `PandaCoreBridge`（uniffi 生成的 `initStore`/`listHosts`/`saveHost`/`deleteHost`/`testConnection`），View 只依赖 `AppBackend` 协议与模型；无 Swift 侧 SSH/SFTP 实现（无 Network/NMSSH 等网络库 import）。
- 平台分支（`#if os(macOS)` / `#if os(iOS)`）共 8 处，全部是 UI 或平台服务：颜色（`NSColor`/`UIColor`）、剪贴板（`NSPasteboard`/`UIPasteboard`）、键盘类型、悬停回调、最小窗口尺寸；无业务逻辑分支。
- 平台服务边界：钥匙串（`KeychainHelper`，Security 框架）与 iCloud KV（`Sync/ConfigSync.swift`）为平台服务，密钥材料由 Swift 从钥匙串取出后作参数传给 FFI，符合契约。
- 附带发现（非本变更范围）：`PandaCoreBackend` 的分组/片段为内存占位实现，注释已标明待后续里程碑；`ConfigSync` 直接读写 `hosts.toml` 文件做 iCloud 同步，属既有的 iCloud 同步方案（本变更明确不处理）。

### 构建门禁（任务 3.1/3.2/4.2）——通过

- `crates/panda-ffi/src/bin/uniffi-bindgen.rs` 已存在（`uniffi::uniffi_bindgen_main()`，uniffi 0.32，与 Cargo.toml `[[bin]]` 声明一致），无需补建。
- `apple/Scripts/build-rust.sh` 一次跑通、无缺陷：三 target（aarch64-apple-darwin / ios / ios-sim）release 静态库 + Swift 绑定 + `PandaCoreFFI.xcframework` 全部产出。
- `cd apple && xcodegen` 成功；`xcodebuild -scheme PandaSSH-macOS build` 与 `xcodebuild -scheme PandaSSH-iOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build` 均 `** BUILD SUCCEEDED **`。
- `cargo test` 全绿；`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过：lines 98.77%、regions 97.41%。

## Open Questions

- 是否需要引入 CI 来自动执行「cargo test + 双端构建」作为架构门禁？当前无 CI，提交前全绿是唯一门禁；可后续补充。
- Linux 目标编译验证受交叉工具链限制（见审计结论 1.3），是否在有 Linux 环境（CI runner 或容器）后补跑一次 `cargo check --target x86_64-unknown-linux-gnu`？
