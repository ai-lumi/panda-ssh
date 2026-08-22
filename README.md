# Panda SSH / 熊猫 SSH

一个极简的 SSH 客户端：Rust 核心 + 原生 UI。支持 SSH 远程连接、SFTP 文件传输、主机标识（known_hosts）保存、密码登录与密钥登录。

目标平台：macOS、iPadOS（前期重点），Linux 后期支持（GTK4，复用同一 Rust 核心）。
跨设备配置同步为下一版本功能。

## 架构

```
┌─────────────────────────────┐  ┌──────────────┐
│  SwiftUI App (macOS/iPadOS) │  │ GTK4 (Linux, │
│  + SwiftTerm 终端           │  │ 后期)        │
└────────────┬────────────────┘  └──────┬───────┘
             │ uniffi FFI               │
┌────────────▼──────────────────────────▼───────┐
│ panda-core (Rust)                             │
│  config / hostkey / ssh(russh) / sftp         │
└───────────────────────────────────────────────┘
```

- `crates/panda-core` — 全部业务逻辑：主机配置（TOML）、known_hosts 校验、SSH 会话、SFTP。
- `crates/panda-ffi` — uniffi 绑定，暴露给 Swift。
- `apple/` — SwiftUI 多平台 App（macOS 14+ / iPadOS 17+），终端模拟用 SwiftTerm。

## 配置存储

- 主机列表等配置：本地 TOML 文件落盘（macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器），路径由 App 注入 Rust 核心。
- 密码 / 私钥口令：系统钥匙串（`kSecAttrSynchronizable`），配置文件只存引用 key，不落密钥材料。

## 构建

> 完整的开发环境搭建、国内镜像配置、测试/运行/打包/发布流程见 **[CONTRIBUTING.md](CONTRIBUTING.md)**。

```sh
# Rust 核心与测试
cargo build
cargo test

# Apple 侧：编译 Rust 多架构静态库并打包 xcframework
apple/Scripts/build-rust.sh

# 生成 Xcode 工程（需要 xcodegen: brew install xcodegen）
cd apple && xcodegen

# 编译 macOS 版
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build
```

说明：

- Xcode 26 起 Metal 工具链为独立组件，SwiftTerm 需要它；如报错缺 Metal Toolchain，先执行 `xcodebuild -downloadComponent MetalToolchain`。
- macOS Debug 构建使用 `PandaSSH-macOS-Dev.entitlements`（仅沙箱 + 网络，ad-hoc 签名即可跑）。
- iOS target 可用模拟器验证（xcframework 的模拟器切片只有 arm64，需限定架构）：`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`。

## 路线图

- [ ] 真实 SSH 服务器联调（密码 / 密钥认证、TOFU 主机密钥确认 UI）
- [ ] 终端交互（SwiftTerm ↔ SSH channel 双向流）
- [ ] SFTP 文件浏览器
- [ ] 跨设备配置同步（待后续版本）
- [ ] 系统钥匙串 / Secure Enclave 密钥支持
- [ ] Linux GTK4 前端

## 开源协议

[Apache License 2.0](LICENSE)。主要依赖的协议均兼容：russh（Apache-2.0）、SwiftTerm（MIT）、uniffi（MPL-2.0，弱 copyleft，可随闭源/Apache 作品分发）。
