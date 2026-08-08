# platform Specification

## Purpose
平台基础架构约束：应用同时支持 macOS 与 iPadOS（SwiftUI 原生界面、共享源码），SSH 等业务逻辑全部位于 Rust 核心并经 uniffi FFI 调用；架构为未来 Linux 与 Windows 复用同一 Rust 核心预留空间。
## Requirements
### Requirement: 双平台支持

应用 SHALL 运行于 macOS 与 iPadOS，且两端 SHALL 共享同一套 SwiftUI 界面源码与同一 Rust 核心产物。

#### Scenario: 双端构建运行

- **WHEN** 按构建流程分别构建 macOS 与 iPadOS target
- **THEN** 两端均可编译运行，且界面源码同源

#### Scenario: 双端共享核心逻辑

- **GIVEN** 用户分别在 macOS 与 iPadOS 上使用同一功能（如连接同一台服务器）
- **THEN** 两端行为一致，且由同一 Rust 核心提供能力

### Requirement: 原生界面与 Rust 核心

界面 SHALL 使用 Swift 原生（SwiftUI）实现，SSH、SFTP、配置等业务逻辑 SHALL 全部位于 Rust 核心，通过 uniffi FFI 调用，MUST NOT 在 Swift 侧重复实现业务逻辑。

#### Scenario: 业务逻辑仅存在于 Rust 核心

- **WHEN** 新增一项业务能力（如主机密钥校验）
- **THEN** 实现位于 `crates/panda-core`，Swift 仅经 FFI 调用

### Requirement: 核心平台无关性

Rust 核心（`panda-core`）MUST NOT 依赖 Apple 平台 API，MUST 保持可被非 Apple 平台编译与复用的平台无关性。

#### Scenario: 核心可在非 Apple 平台编译

- **WHEN** 使用非 Apple 目标编译 `panda-core`
- **THEN** 核心能够通过编译，不引用任何 Apple 平台 API

### Requirement: 未来平台预留

架构 SHALL 为未来 Linux 与 Windows 客户端复用同一 Rust 核心预留空间：新需求不得引入阻碍非 Apple 前端接入的耦合。

#### Scenario: 新逻辑不破坏跨平台复用

- **WHEN** 在核心中新增一项业务逻辑
- **THEN** 该逻辑不依赖 UI 或平台服务，未来 Linux/Windows 前端可复用

### Requirement: FFI 契约稳定

FFI 层 SHALL 保持同步导出与简单数据类型契约，MUST NOT 暴露平台特有类型，以保证多前端复用。

#### Scenario: FFI 导出为平台无关类型

- **WHEN** 新增 FFI 导出函数或类型
- **THEN** 导出使用简单值类型（Record/Enum/Optional/基础类型），不包含平台特有类型

