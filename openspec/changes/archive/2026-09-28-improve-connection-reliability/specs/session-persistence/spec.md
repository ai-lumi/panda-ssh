## Purpose

工作区状态持久化：在 App 关闭前保存标签页结构，启动时恢复，使用户无需每次手动重建工作环境。

## ADDED Requirements

### Requirement: 工作区状态持久化

系统 SHALL 在标签页结构变化时（新建、关闭、重排）将当前工作区状态持久化到配置目录的 `workspace-state.toml`。状态 SHALL 包含每个标签页的主机 ID、标签类型、标签顺序、终端 PTY 尺寸和 SFTP 当前路径。状态 SHALL NOT 包含终端输出缓冲、shell 历史或文件列表缓存。

#### Scenario: 正常保存与恢复

- **GIVEN** 用户打开了两个终端标签和一个 SFTP 标签
- **WHEN** 用户关闭 App 后重新启动
- **THEN** 系统恢复三个标签页结构，自动发起连接

#### Scenario: 无保存状态

- **WHEN** 首次启动或 `workspace-state.toml` 不存在
- **THEN** 工作区显示空态，不报错

#### Scenario: 状态文件损坏

- **WHEN** `workspace-state.toml` 格式非法或字段缺失
- **THEN** 工作区显示空态，SHALL NOT 崩溃，MAY 记录警告日志

### Requirement: 用户配置

系统 SHALL 提供设置项 `restore_workspace_on_launch`（默认 `true`），控制是否在启动时恢复工作区。

#### Scenario: 关闭恢复

- **GIVEN** 用户关闭了 `restore_workspace_on_launch`
- **WHEN** App 启动
- **THEN** 工作区显示空态，不读取或恢复保存的状态

### Requirement: 平台一致性

工作区状态持久化 SHALL 在 macOS 和 iPadOS 上行为一致。业务逻辑在 Rust 核心实现，MUST NOT 使用平台条件编译引入业务分支。

#### Scenario: 双端行为一致

- **GIVEN** 相同的工作区状态文件和设置
- **WHEN** 分别在 macOS 和 iPadOS 上启动 App
- **THEN** 两端恢复的标签页结构和行为完全相同
