## Why

项目目前的 macOS Rust 静态库只包含 Apple Silicon 架构，且没有可重复执行的发布打包流程。维护者不加入 Apple Developer Program 时，仍需要为其他用户提供可下载、可安装的 Intel 与 Apple Silicon 通用 macOS 包。

## What Changes

- 新增无 Developer ID 的 macOS 发布包能力：GitHub Actions 在版本标签触发时构建、测试并产出 ZIP 与 DMG。
- 将 macOS Rust XCFramework 扩展为同时包含 `arm64` 与 `x86_64` 切片。
- 将 macOS Release App 构建限定为 ad-hoc 签名的 Universal App；不配置 Developer ID、Hardened Runtime 或公证。
- 为构建脚本与发布工作流添加可自动验证的契约测试。

## Non-goals

- 不申请或使用 Apple Developer Program、Developer ID 签名、Apple 公证或 Mac App Store 分发。
- 不发布、推送版本标签、创建远端 GitHub Release，也不改变 iPadOS 的发布方式。
- 不改变 SSH、SFTP、凭据存储或任何用户可见业务功能。

## Capabilities

### New Capabilities

- `unsigned-macos-release`: 为 macOS 14+ 提供可复现的无 Developer ID Universal App 构建及 ZIP/DMG 发布工件。

### Modified Capabilities

- `ffi-bridge`: Rust XCFramework 的 macOS slice 从仅 Apple Silicon 扩展为 Intel 与 Apple Silicon。

## Impact

- 修改 `apple/Scripts/build-rust.sh`、`apple/project.yml`，并新增 GitHub Actions 工作流与脚本契约测试。
- macOS 用户将获得 Intel 与 Apple Silicon 都可运行的 ad-hoc 签名包；首次启动仍受 Gatekeeper 的未验证开发者提示约束。
- iPadOS 仍使用既有 arm64 device/simulator slice 与构建配置，不引入行为变化。
