# unsigned-macos-release Specification

## Purpose

为未加入 Apple Developer Program 的维护者提供可复现的 macOS 通用安装包，使其他用户能下载适用于 Intel 与 Apple Silicon Mac 的发布工件。

## Requirements

### Requirement: 无 Developer ID 的 macOS 通用发布工件

系统 SHALL 在版本标签触发的 GitHub Actions 工作流中构建 macOS 14+ 的 ad-hoc 签名 Universal App；该 App MUST NOT 含 Developer ID 或 Apple 公证，并发布包含该 App 的 ZIP 与 DMG 工件。工作流 MUST 在打包前执行 Rust 工作区测试，且构建失败时 MUST NOT 创建发布工件。

#### Scenario: 发布标签触发构建

- **WHEN** 仓库接收到名称匹配 `v*` 的 Git 标签推送
- **THEN** 工作流构建无 Developer ID Universal App、ZIP 与 DMG，并将 ZIP 与 DMG 附加到同名 GitHub Release

#### Scenario: 测试失败阻断发布

- **WHEN** Rust 工作区测试失败
- **THEN** 工作流失败，且不执行创建或上传 GitHub Release 的步骤

### Requirement: 无 Developer ID 分发限制可见

系统 SHALL 在发布说明中告知用户工件未经 Developer ID 签名和 Apple 公证，首次运行可能需要通过 macOS 的"右键打开"确认。系统 MUST NOT 指导用户关闭 Gatekeeper 或执行系统级安全绕过。

#### Scenario: 用户查阅发布说明

- **WHEN** 用户查看 GitHub Release 说明
- **THEN** 可看到无 Developer ID / 无公证状态与安全的首次启动步骤
