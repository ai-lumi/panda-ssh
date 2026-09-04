## MODIFIED Requirements

### Requirement: 连接监控页面入口

macOS 与 iPadOS 的工作区 SHALL 提供进入连接监控页面的入口。macOS 入口 SHALL 在独立窗口展示连接监控，并在窗口已存在时激活该窗口；打开或激活监控窗口 MUST NOT 替换主窗口内容，也 MUST NOT 修改主窗口的主机、分组、标签页或工作区呈现选择。iPadOS 入口 SHALL 继续在主工作区内展示连接监控页面。该页面 SHALL 展示 FFI 返回的当前连接与通道快照，并支持用户手动刷新及对单条连接发起健康检查。页面刷新 MUST NOT 建立新连接或改变工作区标签页。

#### Scenario: 手动刷新监控页面
- **GIVEN** 用户已打开连接监控页面
- **WHEN** 用户选择刷新
- **THEN** 页面显示最新可用快照，且现有终端、SFTP 标签页和连接状态不因刷新而改变

#### Scenario: 双平台入口可达
- **WHEN** 用户在 macOS 或 iPadOS 的工作区选择连接监控入口
- **THEN** 系统按照各平台的呈现策略展示同一语义的连接监控页面和空状态处理

#### Scenario: macOS 独立窗口入口
- **GIVEN** macOS 主窗口正在展示主机详情、终端或 SFTP 工作区
- **WHEN** 用户选择连接监控入口
- **THEN** 系统打开或激活独立的连接监控窗口，且主窗口内容与选择保持不变

#### Scenario: iPadOS 工作区入口
- **WHEN** 用户在 iPadOS 工作区选择连接监控入口
- **THEN** 系统在主工作区展示连接监控页面和空状态处理
