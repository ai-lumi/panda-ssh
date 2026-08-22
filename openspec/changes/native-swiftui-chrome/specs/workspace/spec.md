## MODIFIED Requirements

### Requirement: 主窗口工具栏精简

主窗口 SHALL NOT 展示无意义的 `>>` 按钮。主窗口右上角 SHALL NOT 出现该多余控件；若其为系统自动注入的侧栏切换入口，SHALL 通过隐藏或移除该自动注入项实现。

macOS 主窗口 SHALL 使用原生 SwiftUI 布局构建顶部框架，MUST NOT 依赖 `NSTitlebarAccessoryViewController` 或 AppKit  titlebar accessory 挂载自定义工具栏。侧栏顶部工具栏与内容区顶部页签栏均作为 SwiftUI 视图内嵌于 `NavigationSplitView` 中，而非悬浮于标题栏区域。

#### Scenario: 主窗口无 titlebar accessory

- **GIVEN** 用户在 macOS 上打开主窗口
- **WHEN** 检查窗口的 `titlebarAccessoryViewControllers`
- **THEN** 不存在由应用自定义添加的 accessory view controller
- **AND** 侧栏顶部可见「添加主机」与「新建分组」按钮
- **AND** 内容区顶部可见页签栏，页签栏最左侧有「隐藏/显示侧边栏」按钮

#### Scenario: 页签栏与侧栏顶部对齐

- **GIVEN** 主窗口处于标准大小且侧栏可见
- **WHEN** 用户观察窗口顶部
- **THEN** 侧栏顶部工具栏与内容区顶部页签栏的下边缘处于同一水平线
- **AND** 两者上边缘均对齐窗口内容区的最顶部（红绿灯下方）

## ADDED Requirements

### Requirement: 内容区页签栏侧边栏显隐按钮

内容区顶部页签栏的最左侧 SHALL 放置一个「隐藏/显示左侧边栏」按钮，用于切换侧栏的展开与折叠。侧栏可见时按钮图标表示可隐藏；侧栏隐藏时按钮图标表示可显示。

#### Scenario: 点击按钮隐藏侧栏

- **GIVEN** 侧栏处于可见状态
- **WHEN** 用户点击页签栏最左侧的「隐藏侧栏」按钮
- **THEN** 侧栏折叠，内容区横向扩展填满原侧栏区域
- **AND** 按钮图标变为表示「显示侧栏」的状态

#### Scenario: 点击按钮显示侧栏

- **GIVEN** 侧栏处于隐藏状态
- **WHEN** 用户点击页签栏最左侧的「显示侧栏」按钮
- **THEN** 侧栏展开
- **AND** 按钮图标变为表示「隐藏侧栏」的状态

### Requirement: 侧边栏顶部操作按钮

macOS 侧栏顶部（红绿灯避让区）SHALL 放置「添加主机」与「新建分组」按钮，供用户快速创建主机或分组。该区域在侧栏隐藏时不可见。

#### Scenario: 点击添加主机

- **GIVEN** 主窗口侧栏可见
- **WHEN** 用户点击侧栏顶部的「添加主机」按钮
- **THEN** 弹出添加主机编辑页

#### Scenario: 点击新建分组

- **GIVEN** 主窗口侧栏可见
- **WHEN** 用户点击侧栏顶部的「新建分组」按钮
- **THEN** 弹出新建分组输入框
