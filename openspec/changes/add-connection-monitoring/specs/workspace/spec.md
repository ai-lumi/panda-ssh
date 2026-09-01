## ADDED Requirements

### Requirement: 连接监控页面入口

macOS 与 iPadOS 的工作区 SHALL 提供进入连接监控页面的入口。该页面 SHALL 展示 FFI 返回的当前连接与通道快照，并支持用户手动刷新及对单条连接发起健康检查。页面刷新 MUST NOT 建立新连接或改变工作区标签页。

#### Scenario: 手动刷新监控页面
- **GIVEN** 用户已打开连接监控页面
- **WHEN** 用户选择刷新
- **THEN** 页面显示最新可用快照，且现有终端、SFTP 标签页和连接状态不因刷新而改变

#### Scenario: 双平台入口可达
- **WHEN** 用户在 macOS 或 iPadOS 的工作区选择连接监控入口
- **THEN** 系统展示同一语义的连接监控页面和空状态处理
