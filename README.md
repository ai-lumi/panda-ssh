# Panda SSH / 熊猫 SSH

面向 macOS 与 iPadOS 的原生 SSH 客户端。项目用 Rust 承载跨平台业务核心，以 SwiftUI 提供 Apple 平台界面；当前已覆盖主机管理、SSH 交互终端、SFTP 文件操作与传输任务、代码片段、连接观测和运行日志。

当前最低部署目标为 macOS 14 与 iPadOS 17。Linux 前端仍处于规划阶段，但会复用同一 Rust 核心。

## 全局架构

```text
┌──────────────────────────────────────────────────────────────────┐
│ Apple 应用：apple/PandaSSH（SwiftUI，macOS / iPadOS 共享源码）     │
│                                                                    │
│ 主机与设置 │ 工作区标签页 │ SwiftTerm / iPad 终端 │ SFTP 与传输面板 │
└───────────────────────────────┬──────────────────────────────────┘
                                │ PandaCoreBridge / UniFFI 生成的 Swift 绑定
┌───────────────────────────────▼──────────────────────────────────┐
│ FFI：crates/panda-ffi                                              │
│ 同步导出；共享 Tokio runtime 执行异步 SSH、SFTP、传输与会话工作     │
└───────────────────────────────┬──────────────────────────────────┘
                                │ Rust API
┌───────────────────────────────▼──────────────────────────────────┐
│ 核心：crates/panda-core                                             │
│ 配置/凭据/known_hosts │ SSH(russh) │ SFTP(russh-sftp) │ 工作区状态 │
│ 批量传输/任务聚合 │ 连接遥测 │ 日志 │ 配置导入导出 │ 片段/分组     │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                    本地 TOML、凭据文件、SSH/SFTP 远端
```

### 分层边界

- **SwiftUI 只负责界面与 Apple 平台服务。** `apple/PandaSSH` 通过 `AppBackend` / `PandaCoreBackend` 调用 FFI；`MockBackend` 只服务 Preview 与单元测试。
- **业务规则在 Rust。** 主机、分组、主机密钥、认证、SSH/SFTP、传输、连接与工作区状态的可复用规则均在 `panda-core`，避免 macOS 和 iPadOS 分叉行为。
- **FFI 是稳定边界。** `panda-ffi` 把 Rust 类型转换为 UniFFI 可导出的 Record/Enum，并用惰性初始化的全局 Tokio runtime 承接异步工作；Swift 调用侧仍是同步接口。
- **生成物不入库。** Rust XCFramework、UniFFI Swift 绑定与 Xcode 工程都由脚本生成，详见后文的构建顺序。

## 代码地图

```text
.
├── crates/
│   ├── panda-core/                 # 与 UI、平台无关的 Rust 业务核心
│   │   ├── src/
│   │   │   ├── config.rs           # 主机配置的 TOML 读写与搜索
│   │   │   ├── groups.rs           # 树形分组、移动、级联删除、侧栏树
│   │   │   ├── credentials.rs      # 凭据引用、加密凭据文件与解析
│   │   │   ├── hostkey.rs          # known_hosts、指纹、未知/变更主机密钥
│   │   │   ├── ssh.rs              # 认证、命令、PTY Shell 与会话
│   │   │   ├── sftp.rs             # SFTP 浏览、增删目录/文件、传输原语
│   │   │   ├── batch.rs            # 批量上传/下载扫描、冲突与进度
│   │   │   ├── task_aggregation.rs # 传输任务分组、重试和取消计划
│   │   │   ├── workspace.rs        # 标签页与终端会话状态转换规则
│   │   │   ├── connection_registry.rs / telemetry.rs
│   │   │   │                         # 长连接登记、健康检查和生命周期遥测
│   │   │   ├── logger.rs           # 内存/文件运行日志
│   │   │   ├── snippets.rs         # 代码片段持久化
│   │   │   └── config_archive.rs   # 配置导入导出 ZIP
│   │   └── tests/                  # Fake SSH/SFTP 与可选真实服务器集成测试
│   └── panda-ffi/                  # UniFFI 桥接层及 FFI 集成测试
│       └── src/
│           ├── ffi_store.rs        # 初始化、配置、分组、凭据、主机密钥
│           ├── ffi_sessions.rs     # Shell/SFTP 会话及连接入口
│           ├── ffi_runtime.rs      # 共享异步运行时
│           ├── ffi_transfers.rs    # 传输域入口与单文件传输任务
│           ├── batch_transfer.rs   # 传输域子模块：批量传输任务
│           ├── task_aggregation.rs # 传输域子模块：任务聚合
│           ├── ffi_workspace.rs    # 标签页、终端会话、TOFU 协调
│           ├── ffi_telemetry.rs    # 连接遥测与日志
│           └── bin/uniffi-bindgen.rs # Swift 绑定生成命令
├── apple/
│   ├── PandaSSH/                   # 共享 SwiftUI App 源码
│   │   ├── Auth/                   # 凭据解析与私钥选择
│   │   ├── Mock/                   # AppBackend 协议、内存后端与测试模型
│   │   ├── Workspace/              # 终端、SFTP、标签页、传输与工作区 UI
│   │   ├── PandaCoreBridge.swift   # Rust 初始化与生成绑定的入口
│   │   └── PandaCoreBackend.swift  # FFI 到 UI 后端协议的适配
│   ├── PandaSSHTests/              # macOS/iOS 共用 XCTest
│   ├── Rust/                       # 本地生成：Swift 绑定、头文件、XCFramework
│   ├── Scripts/build-rust.sh       # 多架构 Rust 构建与 UniFFI 绑定生成
│   └── project.yml                 # XcodeGen 唯一工程定义，不手改 xcodeproj
├── openspec/
│   ├── specs/                      # 已生效行为的唯一规格事实来源
│   └── changes/                    # 进行中和已归档的变更提案
├── .github/workflows/              # macOS 无 Developer ID 发布构建
├── Cargo.toml                      # Rust workspace 与共享依赖
├── CONTRIBUTING.md                 # 贡献、网络镜像、发布和故障排查细节
└── AGENTS.md                       # OpenSpec、TDD、覆盖率与架构约束
```

### 关键运行链路

1. `PandaSSHApp` 创建 `PandaCoreBridge`，向 FFI 的 `init_store` 注入应用配置目录。
2. `PandaCoreBackend` 将 SwiftUI 的主机、终端、SFTP 和传输请求映射到 UniFFI。
3. `panda-ffi` 维护全局 store、会话与任务句柄，在共享 Tokio runtime 上调用 `panda-core`。
4. `panda-core` 执行持久化、主机密钥校验、SSH/SFTP I/O；结果再沿 FFI 返回界面。

首次连接未知主机时，默认路径会返回主机公钥和 SHA-256 指纹给 UI 确认；确认后才写入 `known_hosts`。已记录主机的密钥变化会阻断连接。

## 本地数据与安全边界

应用配置目录由 Apple App 注入 Rust 核心：macOS 通常为 `~/.panda-ssh/`，iPadOS 为 App Group 容器（不可用时使用应用 Documents 目录）。核心文件包括：

| 文件 | 内容 | 安全属性 |
|---|---|---|
| 主机、分组、片段等 TOML | 非敏感配置与凭据引用（`*_ref`） | 不保存密码或私钥口令 |
| `known_hosts` | 已信任服务器的主机公钥 | 用于识别未知主机与密钥变更 |
| `credentials.toml` | 密码、私钥口令等凭据材料 | 可选保护密钥；采用 Argon2 派生密钥和 AES-256-GCM 加密 |
| 运行日志文件（启用时） | 诊断记录 | 不应包含密钥材料 |

私钥文件本身由用户指定路径；其口令作为凭据材料处理。密钥材料不通过主机配置 TOML 保存。

## 环境准备

当前 Apple App 的开发和构建需要 macOS。Linux 前端尚未实现。

| 工具 | 最低/建议版本 | 用途 |
|---|---:|---|
| macOS | 14+ | 构建宿主与 macOS App 运行环境 |
| Xcode | 26+ | SwiftUI、xcodebuild、XCFramework 打包 |
| Metal Toolchain | Xcode 26 对应组件 | SwiftTerm Metal 渲染所需 |
| Rust stable | 1.93+ | `panda-core` 与 `panda-ffi` |
| Rust Apple targets | 见下方命令 | macOS/iOS 静态库切片 |
| XcodeGen | 最新版 | 从 `apple/project.yml` 生成 Xcode 工程 |
| cargo-llvm-cov | 最新兼容版 | Rust 覆盖率门禁 |
| Node.js | 20.19+（仅改规格时） | OpenSpec CLI |

安装或检查环境：

```sh
# Xcode 与命令行工具安装完成后
xcodebuild -version
rustc --version
cargo --version

# Rust Apple target：构建 XCFramework 必需
rustup target add aarch64-apple-darwin x86_64-apple-darwin \
  aarch64-apple-ios aarch64-apple-ios-sim

# 从 project.yml 生成工程所需
brew install xcodegen

# Rust 覆盖率门禁所需
cargo install cargo-llvm-cov

# 若 SwiftTerm 报缺少 Metal 工具链（只需一次）
xcodebuild -downloadComponent MetalToolchain
```

`brew install`、`cargo install` 与组件下载会改动本机环境或访问网络；仅在需要时执行。国内网络镜像、代理、发布与更完整的故障排查见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 从零构建

从仓库根目录执行。第一次构建会下载 Rust crates 和 Swift Package 依赖。

```sh
# 1. 验证 Rust workspace
cargo build --workspace
cargo test --workspace

# 2. 构建 4 个 Apple Rust 切片，生成 Swift 绑定和 PandaCoreFFI.xcframework
apple/Scripts/build-rust.sh

# 3. 根据工程定义生成本地 Xcode 工程
(cd apple && xcodegen)

# 4. 构建 macOS Debug App
xcodebuild -project apple/PandaSSH.xcodeproj \
  -scheme PandaSSH-macOS -configuration Debug build

# 5. 验证 iOS 编译与链接（不要求本机配置开发团队或签名）
xcodebuild -project apple/PandaSSH.xcodeproj \
  -scheme PandaSSH-iOS \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

构建顺序不可调换：`build-rust.sh` 会先编译 macOS Apple Silicon、macOS Intel、iOS 设备与 iOS 模拟器切片，再从 macOS 动态库生成 UniFFI Swift 绑定，最后打包 XCFramework。`xcodegen` 必须在绑定生成后执行，才能把 `apple/Rust/Generated/` 中的 Swift 文件纳入工程。

以下路径是本地生成物，受 `.gitignore` 忽略；新检出仓库或清理后必须重新生成：

- `apple/Rust/PandaCoreFFI.xcframework/`
- `apple/Rust/Generated/`
- `apple/Rust/Headers/`
- `apple/PandaSSH.xcodeproj/`

若改动 FFI 导出，重跑 `apple/Scripts/build-rust.sh`；若改动 target、依赖、entitlement 或源码归属，改 `apple/project.yml` 后重跑 `xcodegen`，不要手改生成的 `.xcodeproj`。

### iPadOS 模拟器构建

当前模拟器 XCFramework 切片是 arm64，需在 Apple Silicon Mac 上显式限制架构：

```sh
xcodebuild -project apple/PandaSSH.xcodeproj \
  -scheme PandaSSH-iOS \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

macOS Debug 使用 `PandaSSH-macOS-Dev.entitlements`，采用 ad-hoc 签名即可运行，无需付费 Apple Developer 账号。真机或发行签名属于另行配置；参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 测试与质量门禁

项目实行 OpenSpec 与 TDD：功能或行为变更先创建 `openspec/changes/<change-name>/` 提案，测试任务先于实现任务；完成后同步规格并归档变更。当前正式规格在 `openspec/specs/`。

### 日常验证

```sh
# Rust：所有单元测试与集成测试
cargo test --workspace

# Rust：静态检查
cargo clippy --workspace --all-targets

# Rust：覆盖率门禁（core/FFI 分报告，行与 region 均至少 95%，并核对业务 FFI 文件）
bash scripts/verify-rust-coverage.sh

# Swift：先确保已执行 build-rust.sh 与 xcodegen
xcodebuild -project apple/PandaSSH.xcodeproj \
  -scheme PandaSSH-macOS -configuration Debug test

# iPadOS 模拟器 XCTest：将 <已安装的 iPad 模拟器名称> 替换为本机名称
xcodebuild -project apple/PandaSSH.xcodeproj \
  -scheme PandaSSH-iOS \
  -destination 'platform=iOS Simulator,name=<已安装的 iPad 模拟器名称>' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

| 验证层 | 主要覆盖对象 |
|---|---|
| `panda-core` 单元测试 | 配置、凭据保护、分组树、known_hosts、路径、任务与状态转换 |
| `panda-core` 集成测试 | 进程内 Fake SSH/SFTP server 的认证、命令、Shell 与文件传输 |
| `panda-ffi` 测试 | FFI 错误映射、store/会话/传输与 fake server 联动 |
| `PandaSSHTests` | 后端适配、选择与导航、终端/SFTP/传输状态、工作区和交互策略 |
| 发布契约脚本 | 无 Developer ID 的 macOS Universal 打包静态约束 |

真实服务器联调默认不参与常规测试；需要时显式运行被忽略的测试，并仅使用你有权访问的测试服务器：

```sh
cargo test -p panda-core --test real_server -- --ignored
```

规格变更还应校验 OpenSpec：

```sh
npx @fission-ai/openspec@latest validate --specs --strict
```

## 贡献与发布

提交前至少保证受影响层的测试、构建与覆盖率门禁通过；涉及 FFI 或工程结构时，按“Rust 绑定 → XcodeGen → Xcode”顺序完整验证。详细的提案流程、国内网络配置、运行、打包、发布和常见错误请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，项目约束见 [AGENTS.md](AGENTS.md)。

## 开源协议

[Apache License 2.0](LICENSE)。主要依赖许可兼容：russh 为 Apache-2.0、SwiftTerm 为 MIT、UniFFI 为 MPL-2.0。
