## ADDED Requirements

## Requirement: iPad 导航与页签共用顶行
iPad 统一工作区 SHALL 在系统导航栏中展示页签，内容区 MUST NOT 再绘制独立页签行。系统侧栏入口和状态栏安全区 SHALL 保留。此装配 MUST NOT 改变 macOS 顶部栏布局。

#### Scenario: 侧栏显隐与旋转
- **WHEN** iPad 侧栏展开、隐藏或窗口宽度变化
- **THEN** 页签与系统导航共用一行，页签视口随可用宽度调整

#### Scenario: 多页签与空页签
- **WHEN** 页签为空或超出视口宽度
- **THEN** 显示既有空态或提供既有滚动交互，内容区不额外占用一行
