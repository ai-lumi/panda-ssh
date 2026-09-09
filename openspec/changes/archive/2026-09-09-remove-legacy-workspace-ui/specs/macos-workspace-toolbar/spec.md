## ADDED Requirements

### Requirement: macOS 主窗口工具带布局

macOS SHALL 在唯一顶行中显示侧栏操作区与独立页签容器，下方由 NSSplitViewController 承载共享侧栏及内容视图。顶行 SHALL 使用实测侧栏宽度和原生窗口安全区；iPadOS SHALL 保留 NavigationSplitView 与系统导航栏。

#### Scenario: 打开工作区

- **WHEN** 用户打开工作区
- **THEN** 系统按上述约束呈现统一 UI

### Requirement: 自定义页签按钮平铺统一顶行

统一顶行页签容器中的页签按钮 SHALL 使用自定义 SwiftUI 按钮实现，不使用原生 `TabView` 的页签样式。页签按钮 SHALL 沿工具带水平平铺，每个按钮显示彩色状态圆点、页签标题和关闭按钮。当前活动页签按钮 SHALL 有视觉高亮。

#### Scenario: 打开多个页签

- **GIVEN** 用户已打开多个标签页
- **THEN** 统一顶行页签容器按顺序平铺显示所有页签按钮，且仅有一个当前活动按钮处于高亮态

#### Scenario: 点击非活动页签按钮

- **GIVEN** 用户已打开多个标签页
- **WHEN** 用户点击非活动页签按钮
- **THEN** 该页签成为活动页签，对应内容区切换到该标签页

#### Scenario: 点击页签关闭按钮

- **GIVEN** 用户已打开一个或多个标签页
- **WHEN** 用户点击页签按钮上的关闭按钮
- **THEN** 系统请求关闭该页签；已连接终端按共享规则确认后关闭，取消则保留会话

### Requirement: 页签按钮平铺与溢出处理

页签 SHALL 在统一顶部容器中水平排列，溢出时通过滚动及左右浏览按钮显露。应用 MUST NOT 根据历史多行显示偏好启用旧布局。

#### Scenario: 历史偏好

- **WHEN** 历史溢出模式为多行、空值或非法值
- **THEN** 仍使用统一单行容器，不读取或改写旧偏好

### Requirement: 无标签页时显示提示

零页签时统一顶行 SHALL 显示「暂无已打开页签」，不显示滚动控件，并保留当前侧栏状态对应的操作或恢复入口。主内容区 SHALL 继续显示现有空态。

#### Scenario: 打开工作区

- **WHEN** 用户打开工作区
- **THEN** 系统按上述约束呈现统一 UI

## MODIFIED Requirements

### Requirement: macOS 工具带不含新建标签页按钮

macOS 统一顶行页签容器 MUST NOT 包含「+」新建标签页按钮。新建标签页的入口 SHALL 保留在左侧边栏主机条目（双击打开终端、右键菜单「打开终端 / 浏览文件 (SFTP)」）。

#### Scenario: 打开主窗口

- **WHEN** 用户在 macOS 打开主窗口
- **THEN** 工具带最右侧不出现「+」按钮；用户仍可通过侧栏主机条目新建标签页

## REMOVED Requirements

### Requirement: 内容区顶部工具带

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 自定义页签按钮平铺内容区顶部

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 页签溢出可切换为扩展显示

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 无标签页时工具带为空

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。
