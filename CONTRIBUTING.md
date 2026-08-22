# 开发者指引 — Panda SSH / 熊猫 SSH

本文档覆盖从零搭建开发环境到发布分发的完整流程。项目强制 OpenSpec 流程与 TDD，细则见 [AGENTS.md](AGENTS.md)。

## 目录

- [1. 环境要求](#1-环境要求)
- [2. 国内网络镜像 / 代理配置](#2-国内网络镜像--代理配置)
- [3. 首次搭建（从零到跑起来）](#3-首次搭建从零到跑起来)
- [4. 日常开发流程](#4-日常开发流程)
- [5. 测试](#5-测试)
- [6. 运行](#6-运行)
- [7. 打包与发布](#7-打包与发布)
- [8. 故障排查](#8-故障排查)

---

## 1. 环境要求

| 工具 | 版本 | 用途 | 安装 |
|------|------|------|------|
| macOS | 14+（开发机建议最新） | 宿主系统 | — |
| Xcode | 26+ | SwiftUI 编译、xcframework 打包 | App Store / Apple Developer |
| Metal Toolchain | 随 Xcode 26 单独下载 | SwiftTerm 的 Metal 渲染 | `xcodebuild -downloadComponent MetalToolchain` |
| Rust | 1.93+（stable） | 核心库 | rustup（见镜像节） |
| XcodeGen | latest | 从 `apple/project.yml` 生成 .xcodeproj | `brew install xcodegen` |
| Node.js | ≥ 20.19 | OpenSpec CLI（npx 即用，可不全局装） | brew / nvm |
| Apple Developer 账号 | 免费可开发，**付费（$99/年）才可真机分发** | 签名 | developer.apple.com |

> Linux 前端（GTK4）尚未开始，当前开发必须在 macOS 上进行。

## 2. 国内网络镜像 / 代理配置

项目依赖链较长（Rust crates、Homebrew、npm、GitHub SPM、Apple CDN），国内网络建议按下表配置。全部配置均为「写到 shell 配置文件一次，长期生效」；如已有代理，优先走代理并跳过镜像。

### 2.1 rustup（Rust 工具链与 target 下载）

```sh
# 写入 ~/.zshrc
export RUSTUP_DIST_SERVER="https://rsproxy.cn"
export RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
```

备选：清华 TUNA `https://mirrors.tuna.tsinghua.edu.cn/rustup`、中科大 `https://mirrors.ustc.edu.cn/rust-static`。

已知坑：多个 rustup 进程并发下载会在 `~/.rustup/downloads/` 留下 `.partial` 残骸导致后续安装报 rename 失败，删掉残骸重试即可：`rm -f ~/.rustup/downloads/*.partial`。

### 2.2 cargo（crates.io 依赖）

写入 `~/.cargo/config.toml`（rsproxy 稀疏镜像）：

```toml
[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[registries.rsproxy]
index = "sparse+https://rsproxy.cn/index/"

[net]
git-fetch-with-cli = true
```

备选：中科大 `sparse+https://mirrors.ustc.edu.cn/crates.io-index/`、字节 `sparse+https://rsproxy.cn/index/` 同源。

### 2.3 Homebrew

```sh
# 中科大镜像（写入 ~/.zshrc）
export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
```

日常安装建议加 `HOMEBREW_NO_AUTO_UPDATE=1 brew install <pkg>`，避免每次装包都先同步一遍仓库。

### 2.4 npm（OpenSpec CLI）

```sh
npm config set registry https://registry.npmmirror.com
```

注意：如果 `~/.npmrc` 里配置了失效的企业私有源（症状：`getaddrinfo ENOTFOUND xn--nginx-...` 之类），不必改全局配置，单次命令覆盖即可：

```sh
npm_config_registry=https://registry.npmjs.org npx -y @fission-ai/openspec@latest <args>
```

### 2.5 Swift Package Manager（GitHub 依赖）

SPM 依赖（SwiftTerm）直接走 GitHub，无官方镜像。可选方案按推荐排序：

1. 给终端配代理：`export https_proxy=http://127.0.0.1:7890`（端口按你的代理软件调整）。
2. GitHub 加速镜像做 URL 重写（写入 `~/.gitconfig`）：
   ```
   [url "https://gh-proxy.com/https://github.com/"]
       insteadOf = https://github.com/
   ```
   （镜像站可用性随时间变化，失效就换一个或回到方案 1。）
3. 先在代理环境下用 Xcode/xcodebuild 拉一次依赖，之后有本地缓存（`~/Library/Caches/org.swift.swiftpm` 与 DerivedData）可离线编译。

### 2.6 Apple 组件（Metal Toolchain、模拟器运行时）

Apple CDN（`swcdn` / MobileAsset）无第三方镜像。`xcodebuild -downloadComponent MetalToolchain` 约 700MB，国内直连通常可达但慢，建议挂代理或在网络空闲时段执行；下载中断重跑命令会续传。

## 3. 首次搭建（从零到跑起来）

```sh
# 1. 克隆
git clone <repo-url> panda-ssh && cd panda-ssh

# 2. Rust 工具链 + Apple 三个 target（配好镜像后执行）
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim

# 3. Metal Toolchain（SwiftTerm 需要，只需一次）
xcodebuild -downloadComponent MetalToolchain

# 4. Rust 核心：编译 + 测试
cargo build
cargo test        # 应全部通过

# 5. 编译三架构静态库 → 生成 Swift 绑定 → 打包 xcframework
apple/Scripts/build-rust.sh

# 6. 生成 Xcode 工程（PandaSSH.xcodeproj 被 gitignore，必须本地生成）
cd apple && xcodegen && cd ..

# 7. 编译 macOS App（Debug 用 ad-hoc 签名，无需开发者账号）
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -configuration Debug build
```

顺序约束：`build-rust.sh` 必须在 `xcodegen` 之前跑（生成 `apple/Rust/Generated/` 的 Swift 绑定，否则工程缺文件）。这三样产物——`apple/Rust/PandaCoreFFI.xcframework`、`apple/Rust/Generated/`、`apple/PandaSSH.xcodeproj`——都在 `.gitignore` 里，**每次全新检出都必须重跑第 5、6 步**。

iOS/iPadOS 模拟器验证（可选）：

```sh
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

（xcframework 的模拟器切片只有 arm64，Apple Silicon 开发机需显式限定架构。）

## 4. 日常开发流程

本项目强制 **OpenSpec + TDD**（见 AGENTS.md），流程如下：

1. **提变更提案**：任何新功能/行为变更，先建提案
   ```sh
   npx @fission-ai/openspec@latest <...>   # 或用 Kimi Code 的 /skill:openspec-propose
   ```
   提案放在 `openspec/changes/<name>/`：proposal.md（含 Non-goals）、tasks.md（测试任务排在实现任务之前）、specs/ 下的 delta。
2. **校验提案**：`npx @fission-ai/openspec@latest validate <name> --strict`
3. **TDD 实现**：先写失败测试（red）→ 最小实现（green）→ 重构。Rust 侧外部依赖用 trait 隔离；SSH/SFTP 用 `crates/panda-core/tests/fake_server.rs` 的进程内 fake server 写集成测试，不需要真实服务器。
4. **改了 FFI 导出**（`crates/panda-ffi`）后必须重跑 `apple/Scripts/build-rust.sh` 刷新 Swift 绑定，否则 Swift 侧看到的还是旧接口。
5. **改了工程结构**（加文件 target 归属、entitlements、依赖）改 `apple/project.yml` 后重跑 `cd apple && xcodegen`，**不要手改 .xcodeproj**。
6. **收尾归档**：实现完成、验证全绿后
   ```sh
   npx @fission-ai/openspec@latest archive <name> -y
   npx @fission-ai/openspec@latest validate --specs --strict
   ```

提交前门禁（无 CI，全靠自觉）：

```sh
cargo test --workspace && cargo clippy --workspace --all-targets
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -configuration Debug build
```

## 5. 测试

| 层 | 命令 | 说明 |
|----|------|------|
| Rust 单元测试 | `cargo test -p panda-core --lib` | config / hostkey / ssh 判定逻辑 |
| Rust 集成测试 | `cargo test -p panda-core --test fake_server` | 进程内 fake SSH/SFTP server，覆盖认证、exec、超时、文件传输 |
| FFI 测试 | `cargo test -p panda-ffi` | 错误映射等 |
| lint | `cargo clippy --workspace --all-targets` | 要求 0 warning |
| spec 校验 | `npx @fission-ai/openspec@latest validate --specs --strict` | 改 specs 后必跑 |
| Swift 侧 | 暂无 XCTest target | 可测逻辑（ConfigSync、KeychainHelper）随 testability 提案补；当前用 xcodebuild 编译兜底 |

真实 SSH 服务器联调属手动验证：本机 `brew install openssh` 或局域网 Linux 机器即可，注意首次连接会触发 known_hosts 写入（当前骨架 FFI 层为静默 TOFU，发布前会切确认式，见 server-management 提案）。

## 6. 运行

**macOS（推荐用 Xcode 跑，方便看日志/断点）**：

```sh
open apple/PandaSSH.xcodeproj   # 选 PandaSSH-macOS scheme，⌘R
```

或命令行构建后直接打开产物：

```sh
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/PandaSSH-*/Build/Products/Debug/PandaSSH.app
```

**iPadOS 模拟器**：Xcode 里选 PandaSSH-iOS scheme + 一台 iPad 模拟器运行。（真机分发需要付费开发者账号签名，见下节。）

Debug 构建使用 `PandaSSH-macOS-Dev.entitlements`（仅沙箱+网络）：App Group 不可用时配置会回退到 Documents 目录——这是预期行为，不是 bug。

## 7. 打包与发布

当前处于骨架阶段，以下是既定路径，随里程碑逐步打通：

**macOS（开发者 ID 分发，绕开 App Store）**：
1. 在 `apple/project.yml` 的 macOS target 把 `CODE_SIGN_IDENTITY` 换成 `Apple Development`/`Developer ID Application` 并填 `DEVELOPMENT_TEAM`。
2. Release 构建使用 `PandaSSH-macOS.entitlements`（沙箱关闭 + 网络客户端）。
3. `xcodebuild -scheme PandaSSH-macOS -configuration Release archive` 导出后公证（`xcrun notarytool submit`）再分发。

**iPadOS（App Store / TestFlight）**：
1. 同样需要付费账号、App ID 能力配置与描述文件。
2. `xcodebuild -scheme PandaSSH-iOS -configuration Release archive` → Xcode Organizer 上传。

**发布前检查清单**（随功能完善扩充）：
- [ ] server-management 提案落地：TOFU 确认式交互取代静默 `AcceptAndStore`（spec 中的发布门禁）
- [ ] 真机联调（系统钥匙串行为实测）
- [ ] `cargo test` / 双端 xcodebuild 全绿
- [ ] 第三方依赖许可证清单（Apache-2.0 兼容性已在 AGENTS.md 约束）

## 8. 故障排查

| 症状 | 原因与解法 |
|------|-----------|
| `error: cannot execute tool 'metal'` | Xcode 26 起 Metal 工具链独立下载：`xcodebuild -downloadComponent MetalToolchain` |
| `requires a provisioning profile`（macOS Debug） | 误用了完整 entitlements 编 Debug。Debug 应走 `PandaSSH-macOS-Dev.entitlements`（project.yml 已按 configuration 拆分，若手改请注意） |
| iOS 模拟器链接报 `found architecture 'arm64', required architecture 'x86_64'` | xcframework 无 x86_64 模拟器切片，构建加 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` |
| rustup 报 `could not rename ... .partial` | 并发下载残骸：`rm -f ~/.rustup/downloads/*.partial` 后重试 |
| npm 报 `ENOTFOUND xn--nginx-...` | 企业私有源失效，单次覆盖：`npm_config_registry=https://registry.npmjs.org npx ...` |
| xcodegen 后工程缺 Swift 绑定文件 | 顺序错了：先 `apple/Scripts/build-rust.sh` 再 `xcodegen` |
| SwiftTerm 拉取超时 | 见 2.5 节配代理或 GitHub 镜像重写 |
| App 里保存主机后列表为空 | Debug 构建无 App Group entitlement，配置回退 Documents；检查 `PandaCoreBridge` 日志路径，属预期降级 |
