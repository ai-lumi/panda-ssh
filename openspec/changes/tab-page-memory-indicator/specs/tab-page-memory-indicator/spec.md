## Purpose

在标签页级别提供轻量内存占用估算，帮助用户感知单个终端或 SFTP 会话的资源消耗，便于在多标签场景下做出关闭或调整决策。

## ADDED Requirements

### Requirement: 终端标签页内存估算

系统 SHALL 为每个终端标签页提供内存占用估算。估算 MUST 基于 SwiftTerm 内部缓冲区的实际行数与当前列数：已连接的终端标签页取其实时缓冲区行数与终端列数；未连接或连接中的终端标签页返回零或「—」。计算结果 MUST 以人类可读格式显示（如「约 12 MB」）。

#### Scenario: 悬停已连接终端标签页显示内存

- **GIVEN** 一个已连接的终端标签页，缓冲区积累了大量输出
- **WHEN** 用户在 macOS 上将鼠标悬停在该标签页按钮上（或在 iPadOS 上长按）
- **THEN** 展示该标签页的内存估算（如「约 12 MB」）

#### Scenario: 悬停未连接终端标签页显示无数据

- **GIVEN** 一个处于连接中或连接失败状态的终端标签页
- **WHEN** 用户触发内存指示交互
- **THEN** 显示「—」或「未连接」，不展示具体数值

### Requirement: SFTP 标签页内存估算

系统 SHALL 为每个 SFTP 标签页提供内存占用估算。估算 MUST 基于本地/远程文件列表条目数与活跃传输任务数量：每个文件列表条目按固定大小估算，每个活跃传输任务按固定开销估算。已连接的 SFTP 标签页 MUST 包含文件列表缓存与传输任务开销；未连接的 SFTP 标签页返回零或「—」。

#### Scenario: 悬停已连接 SFTP 标签页显示内存

- **GIVEN** 一个已连接的 SFTP 标签页，正在浏览包含大量文件的目录
- **WHEN** 用户触发内存指示交互
- **THEN** 展示该标签页的内存估算（如「约 2 MB」）

#### Scenario: 悬停含活跃传输的 SFTP 标签页显示内存

- **GIVEN** 一个 SFTP 标签页有 3 个 running 状态的传输任务
- **WHEN** 用户触发内存指示交互
- **THEN** 展示内存估算包含传输任务开销（如「约 4 MB」）

### Requirement: 平台触发方式

macOS 上 SHALL 通过鼠标悬停（hover）触发内存指示展示；iPadOS 上 SHALL 通过长按（long press）触发。展示形式 MUST 为轻量 Tooltip（macOS）或小型 Popover（iPadOS），SHALL NOT 干扰标签页的正常点击切换或关闭操作。

#### Scenario: macOS 悬停展示 Tooltip

- **WHEN** 用户在 macOS 上将鼠标悬停在某标签页按钮上约 500ms
- **THEN** 在标签页按钮附近弹出 Tooltip，显示该标签页内存估算
- **AND** 鼠标移开后 Tooltip 自动消失

#### Scenario: iPadOS 长按展示 Popover

- **WHEN** 用户在 iPadOS 上长按某标签页按钮约 500ms
- **THEN** 在标签页按钮附近弹出小型 Popover，显示该标签页内存估算
- **AND** 点击 Popover 外部或再次点击标签页时 Popover 消失

#### Scenario: 悬停/长按不干扰正常操作

- **WHEN** 用户快速点击标签页按钮切换或关闭
- **THEN** Tooltip/Popover 不弹出，正常切换/关闭行为不受影响
