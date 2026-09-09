## Purpose

提供跨 macOS 与 iPadOS 的统一工作区顶部 chrome 和独立页签容器，在保留平台原生窗口与导航体验的同时最大化可用工作空间。

## ADDED Requirements

### Requirement: 工作区使用统一的顶部 chrome 与独立页签容器

工作区 SHALL 以单一顶部 chrome 承载侧栏操作入口和独立页签容器，且页签容器 MUST 独立管理可见区、溢出边界、滚动输入、导航控件和活动页签显露。顶部 chrome MUST NOT 导致终端或 SFTP 内容区出现重复页签栏。

#### Scenario: 大量页签浏览

- **GIVEN** 工作区页签总宽度超过可见宽度
- **WHEN** 用户使用页签栏的滚动输入或导航控件浏览
- **THEN** 容器在自身边界内移动，活动 SSH/SFTP 页签不得因浏览页签栏而被切换

#### Scenario: 活动页签显露

- **GIVEN** 活动页签不在页签容器可见区内
- **WHEN** 用户选择该页签或应用恢复该工作区
- **THEN** 页签容器 SHALL 以最小必要位移显露该页签，且不得越过内容边界

### Requirement: 页签规则跨平台共享而平台 chrome 保持原生

macOS 与 iPadOS MUST 共享页签顺序、活动选择、滚动边界、输入归一化和会话生命周期规则。平台差异 SHALL 限于窗口控件、安全区、窗口拖拽和系统导航入口，且不得形成各自独立的页签业务实现。

#### Scenario: 跨平台相同工作区状态

- **GIVEN** 两个平台具有相同的页签数据和活动页签
- **WHEN** 渲染统一工作区 chrome
- **THEN** 页签顺序、活动状态、连接状态和关闭确认语义 MUST 一致

#### Scenario: 平台特有窗口行为

- **GIVEN** 用户在 macOS 或 iPadOS 使用工作区
- **WHEN** 平台呈现窗口控件、安全区或系统导航入口
- **THEN** 平台可使用原生适配行为，但页签业务规则不得改变

### Requirement: 旧内容区页签栏可回退

新工作区 chrome 启用前，应用 MUST 保留旧内容区页签栏及其装配路径。切换新旧路径 MUST NOT 重建、关闭或丢失终端/SFTP 会话。

#### Scenario: 新路径不可用

- **GIVEN** 新工作区 chrome 被明确禁用或未通过布局验证
- **WHEN** 用户打开工作区
- **THEN** 应用 SHALL 回退至旧内容区页签栏并保持已有会话状态
