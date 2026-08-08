## Purpose

代码片段能力（低优先级，预留）：以 Markdown 文件管理常用命令与脚本片段，支持选择存储路径，便于用户复用与手工维护。

## ADDED Requirements

### Requirement: 代码片段管理（预留）

系统 SHALL 支持代码片段的新建、查看、编辑、删除与复制，每个片段为一个 Markdown 文件。

#### Scenario: 查看片段列表

- **GIVEN** 存储目录中已有片段文件
- **WHEN** 用户打开片段面板
- **THEN** 系统列出所有片段及其标题、标签与说明

#### Scenario: 复制片段内容

- **WHEN** 用户选择一个片段
- **THEN** 系统允许用户复制该片段的代码内容

### Requirement: 存储路径可选

用户 SHALL 能选择代码片段的存储目录，系统 MUST 按用户所选目录读写片段文件。

#### Scenario: 更改存储目录

- **WHEN** 用户在设置中选择新的片段存储目录
- **THEN** 系统切换到该目录读写片段

#### Scenario: 目录内已有 Markdown 文件可见

- **WHEN** 所选存储目录内存在符合格式的 Markdown 文件
- **THEN** 系统将其作为片段展示

### Requirement: Markdown 存储格式

每个代码片段 SHALL 以独立的 Markdown（`.md`）文件存储，包含标题、标签、说明与代码内容。

#### Scenario: 片段落盘为 Markdown 文件

- **WHEN** 用户新建一个片段并保存
- **THEN** 系统在存储目录写入一个 Markdown 文件，其中包含该片段的标题、标签、说明与代码

### Requirement: 预留约束（低优先级）

本能力 SHALL 按低优先级预留：规格与设计先行，实现阶段不占用当前排期，MUST NOT 阻塞其它能力的开发与交付。

#### Scenario: 预留不影响主线开发

- **WHEN** 其它核心能力进入实现阶段
- **THEN** 本能力保持「预留」状态，不进入实现排期，不影响其它能力交付
