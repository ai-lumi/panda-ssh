## MODIFIED Requirements

### Requirement: 主窗口工具栏精简

macOS 主窗口 SHALL 保留原生窗口控制、缩放、全屏与空白窗口拖拽能力。macOS 工作区 SHALL 使用透明标题栏与全尺寸内容承载统一顶部 chrome；页签栏 MUST NOT 被注册为系统工具栏的 principal item，且顶部 chrome SHALL 避让红绿灯与其他原生窗口交互区。工作区顶部 chrome SHALL 同时提供侧栏操作入口和独立页签栏，以避免页签栏与 detail 内容区重复占用垂直空间。iPadOS SHALL 使用相同的工作区页签与侧栏规则，并保留其原生安全区和导航入口。旧内容区页签栏 SHALL 在新路径验证前保留为可选择回退路径。

#### Scenario: macOS 统一顶部 chrome

- **WHEN** 用户打开包含页签的 macOS 工作区
- **THEN** 页签栏显示在统一顶部 chrome 中，detail 内容区顶部不得重复显示页签栏

#### Scenario: macOS 侧栏隐藏

- **WHEN** 用户隐藏侧栏
- **THEN** 顶部 chrome 保留原生窗口控件安全区与可访问的侧栏恢复入口，其余空间供页签栏使用

#### Scenario: iPadOS 保持原生导航

- **WHEN** 用户在 iPadOS 打开工作区
- **THEN** 系统安全区与导航入口保持可用，页签与会话行为与 macOS 一致

#### Scenario: 回退路径

- **GIVEN** 新统一顶部 chrome 不可用或被明确禁用
- **WHEN** 用户打开 macOS 工作区
- **THEN** detail 内容区显示旧页签栏，已打开会话不得变化
