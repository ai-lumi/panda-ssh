# AGENTS.md — Panda SSH / 熊猫 SSH

极简 SSH 客户端：Rust 核心 + 原生 UI。支持 SSH 远程连接、SFTP 文件传输、主机标识保存、密码与密钥登录。目标平台 macOS / iPadOS（前期重点），Linux 后期。Apache-2.0 开源。

## 两条强制约定

### 1. 基于 OpenSpec 规范开发

本项目使用 [OpenSpec](https://github.com/Fission-AI/OpenSpec) 做规格驱动开发：

- `openspec/specs/` 是系统当前行为的**唯一事实来源**；`openspec/changes/` 存放变更提案。
- 任何新功能、行为变更、架构调整，**必须先在 `openspec/changes/<change-name>/` 下创建变更提案**（proposal / design / tasks / spec deltas），评审后再动手写代码。
- spec 条目用 `## Requirement: <名称>` + `#### Scenario:` 格式，需求语句使用 SHALL/MUST（RFC 2119）。
- 实现完成后将 change 归档，把 delta 合并回 `openspec/specs/`，保持 specs 与代码一致。
- 工作流命令（Kimi Code skills）：`/skill:openspec-propose` 等，见 `.kimi-code/skills/`（每个子目录是一个 SKILL.md，按步骤执行，需安装 openspec CLI）。
- 禁止绕过提案直接实现新行为；bug 修复若改变了已规格化的行为，同样要先改 spec。

### 2. 强制测试驱动开发（TDD）

- 严格 red-green-refactor：**先写会失败的测试，再写最小实现让它通过，然后重构**。没有先写失败测试的实现代码不予接受。
- Rust 侧：`cargo test` 必须全绿；核心逻辑（config、hostkey、ssh、sftp 的可测部分）必须有单元测试；外部依赖（真实 SSH 服务器、钥匙串）通过 trait 抽象隔离，用 fake/mock 测试。
- Swift 侧：可测逻辑（钥匙串封装、模型层）用 XCTest；纯 UI 布局不强制测试。
- 覆盖率门禁：所有代码分支必须有测试覆盖，覆盖率不得低于 95%。提交前必须满足 `lines >= 95%` 且 `regions >= 95%`。
- 用例门禁：每个功能模块的测试用例必须覆盖三类场景——正常流程、意外操作（错误输入/失败路径）、边界条件（空值/极限值/临界状态）。
- 提交前运行 `cargo test`（及改动的 Swift target 测试），红了不许提交。
- 测试与实现放在同一个变更提案的 tasks 里，测试任务排在实现任务之前。

## 构建与测试

```sh
cargo build && cargo test                    # Rust 核心（无 CI，提交前全绿是唯一自动门禁）
cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
apple/Scripts/build-rust.sh                  # 多架构静态库 + xcframework + Swift 绑定
cd apple && xcodegen                         # 生成 Xcode 工程（需 brew install xcodegen）
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build
```

- 顺序重要：`build-rust.sh` → `xcodegen` → `xcodebuild`。`apple/Rust/PandaCoreFFI.xcframework`、`apple/Rust/Generated/`、`apple/PandaSSH.xcodeproj` 都在 `.gitignore`，全新检出必须先跑前两步再编译。
- Swift 绑定由 `cargo run -p panda-ffi --features bindgen-cli --bin uniffi-bindgen` 生成（`bindgen-cli` feature 门控，库构建不会带入 CLI 依赖）。

## 代码结构

- `crates/panda-core` — 业务逻辑全部在此：主机配置（TOML）、分组（groups.toml，树形 + 删除级联）、known_hosts、SSH（russh）、SFTP（russh-sftp）。
- `crates/panda-ffi` — uniffi 绑定，暴露给 Swift。所有导出函数是同步的，异步跑在懒初始化的全局 tokio runtime（`block_on`），不要另起 runtime。`init_store(config_dir)` 把 store 根在 App 注入的配置目录路径（macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器），首次调用生效、之后 no-op；密钥材料不经过 FFI 落盘，密码/口令由 Swift 侧从钥匙串取出后作为 `password`/`passphrase` 参数传入（`test_connection`/`sftp_*`）。
- `apple/PandaSSH` — SwiftUI 多平台源码（macOS/iPadOS 双 target 共享）；`apple/project.yml` 为 XcodeGen 工程定义，改工程结构改它而不是 .xcodeproj。
- `apple/PandaSSH/Mock` — 后端抽象（`AppBackend` 协议）与内存实现（`MockBackend`，原型演示数据）。View 只依赖协议与 `HostEntry`/`HostGroup`/`Snippet` 模型；`AppConfig.useMockBackend` 默认 `false`（UI 运行走真实后端），只有 Preview 与单元测试显式使用 Mock。
- `openspec/` — OpenSpec 规格与变更提案。

### 平台条件编译规范（`#if os()`）

Swift 双端共享源码中，平台条件编译只允许用于**界面与平台服务差异**：

- 允许：UI 差异（颜色/键盘类型/悬停/最小窗口尺寸）、剪贴板（`NSPasteboard` vs `UIPasteboard`）、文件选择器（`NSOpenPanel` vs `UIDocumentPicker`）、钥匙串等平台服务调用。
- 不允许：业务逻辑分支（配置、分组、主机密钥、SSH、SFTP、传输、片段的规则或算法）——这些只能写在 `crates/panda-core`，Swift 侧经 FFI 调用；禁止用 `#if os()` 让某一端走不同的业务行为。

### 架构评审检查清单

新增/修改代码时按此清单评审，任何一条不满足即退回：

1. **分层边界**：新增业务能力（配置、主机密钥、SSH、SFTP、传输、片段等）的实现是否只落在 `crates/panda-core`？Swift 侧是否仅经 FFI/`AppBackend` 调用，没有重复实现业务逻辑？
2. **FFI 契约**：新增 `#[uniffi::export]` 是否保持同步导出（异步在全局 tokio runtime 上 `block_on`，不另起 runtime）？导出类型是否只用简单值类型（Record/Enum/Optional/String/整数等），不含平台特有类型？密钥材料是否仍只作参数传入、不经 FFI 落盘？
3. **依赖平台无关**：`crates/panda-core` 新增依赖是否跨平台可编译（Linux/Windows 可用、无 Apple 专属 crate）？是否 Apache-2.0 兼容？验证方式：`cargo check --target x86_64-unknown-linux-gnu`。
4. **平台分支合规**：新增 `#if os()` 是否只属于上节允许清单（UI/平台服务）？
5. **构建门禁**：`cargo test` 全绿；改动涉及 FFI 或工程结构时，`build-rust.sh` → `xcodegen` → macOS/iOS 双端 `xcodebuild` 通过。

## 约定

- 开源协议：Apache-2.0（见 `LICENSE`），新增依赖必须协议兼容（MIT/BSD/Apache/MPL 均可，GPL/LGPL 不行）。
- 全中文约定：大模型响应、代码注释、文档一律用中文；提交信息保留 Conventional Commits 格式（类型前缀如 feat/fix 用英文），描述用中文。
- 安全红线：密码、私钥口令只存系统钥匙串（`kSecAttrSynchronizable`），配置 TOML 只存 `*_ref` 引用 key，不落密钥材料。
- 当前 host key 行为：首次连接未知主机时，FFI 以 `Reject` 策略探测并返回 `UnknownHostKey`（携带呈现密钥与 SHA256 指纹），由 Swift UI 弹框要求用户确认；用户信任后调用 `accept_unknown_host_key` 存储探测呈现的密钥，再正常连接。连接入口（`test_connection`/`sftp_*`）带 `trust_on_first_use: bool` 参数，`false` 对应 `Reject`，`true` 对应 `AcceptAndStore`（保留给自动化/未来「始终信任」选项）。同一主机的多个并发连接请求在 `AppModel` 层串行化，只弹一次确认框。密钥变更（`HostKeyMismatch`）时阻断连接并展示告警。改动此行为需同步改 spec。
