## MODIFIED Requirements

### Requirement: 页签栏溢出显示模式

macOS 与 iPadOS 页签栏 SHALL 使用共享单行水平滚动容器。溢出时 SHALL 提供左右浏览控件及滚动输入；浏览 MUST NOT 切换活动页签。应用 MUST NOT 提供旧版多行显示设置。

#### Scenario: 大量页签

- **WHEN** 页签总宽度超过视口
- **THEN** 可在容器边界内浏览所有页签，主内容区不因多行换行而下移

### Requirement: 主窗口工具栏精简

macOS SHALL 保留原生窗口控制、缩放、全屏与空白拖拽。应用 SHALL 使用透明标题栏、全尺寸内容及实测红绿灯安全区承载唯一统一顶部 chrome，MUST NOT 使用系统 toolbar 或 principal item 承载页签。iPadOS SHALL 在系统导航栏使用同一页签容器，并保留系统侧栏恢复入口及安全区。应用 MUST NOT 装配旧内容区页签栏。

#### Scenario: 打开双端工作区

- **WHEN** 用户在 macOS 或 iPadOS 打开工作区
- **THEN** 顶部仅有一个页签容器，平台原生控制可用

### Requirement: macOS 主窗口工具带布局

macOS SHALL 在唯一顶行中显示侧栏操作区与独立页签容器，下方由 NSSplitViewController 承载共享侧栏及内容视图。顶行 SHALL 使用实测侧栏宽度和原生窗口安全区；iPadOS SHALL 保留 NavigationSplitView 与系统导航栏。

#### Scenario: 打开工作区

- **WHEN** 用户打开工作区
- **THEN** 系统按上述约束呈现统一 UI

### Requirement: 隐藏/显示左侧边栏入口

macOS 统一顶行 SHALL 在侧栏显示时提供隐藏侧栏按钮，隐藏后提供恢复侧栏按钮。按钮 MUST NOT 在旧内容区工具带或侧栏内重复出现。

#### Scenario: 切换侧栏

- **WHEN** 用户点击顶行侧栏按钮
- **THEN** 侧栏可隐藏并恢复，页签与会话保持不变

### Requirement: 页签按钮平铺与溢出处理

页签 SHALL 在统一顶部容器中水平排列，溢出时通过滚动及左右浏览按钮显露。应用 MUST NOT 根据历史多行显示偏好启用旧布局。

#### Scenario: 历史偏好

- **WHEN** 历史溢出模式为多行、空值或非法值
- **THEN** 仍使用统一单行容器，不读取或改写旧偏好

### Requirement: iPad 侧栏恢复入口唯一
iPad 工作区 SHALL 保留系统导航提供的侧栏恢复入口。统一页签栏 MUST NOT 重复绘制自定义恢复按钮，也 MUST NOT 为该按钮预留宽度。

#### Scenario: 隐藏和恢复侧栏
- **WHEN** 用户隐藏侧栏或反复切换侧栏显隐
- **THEN** 仅保留系统提供的恢复入口，页签栏不显示重复按钮

#### Scenario: 紧凑宽度
- **WHEN** iPad 旋转或进入窄分屏
- **THEN** 页签栏不为自定义恢复按钮占位，系统导航入口保持可用

### Requirement: iPad 导航与页签共用顶行
iPad 统一工作区 SHALL 在系统导航栏中展示页签，内容区 MUST NOT 再绘制独立页签行。系统侧栏入口和状态栏安全区 SHALL 保留。此装配 MUST NOT 改变 macOS 顶部栏布局。

#### Scenario: 侧栏显隐与旋转
- **WHEN** iPad 侧栏展开、隐藏或窗口宽度变化
- **THEN** 页签与系统导航共用一行，页签视口随可用宽度调整

#### Scenario: 多页签与空页签
- **WHEN** 页签为空或超出视口宽度
- **THEN** 显示既有空态或提供既有滚动交互，内容区不额外占用一行
