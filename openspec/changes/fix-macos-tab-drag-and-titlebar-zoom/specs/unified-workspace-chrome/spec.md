## MODIFIED Requirements

### Requirement: 页签规则跨平台共享而平台 chrome 保持原生

macOS 与 iPadOS MUST 共享页签顺序、活动选择、滚动边界、输入归一化和会话生命周期规则。平台差异 SHALL 限于窗口控件、安全区、窗口拖拽和系统导航入口，且不得形成各自独立的页签业务实现。macOS 的窗口拖动 SHALL 仅由顶部 chrome 中不含页签、关闭控件或侧栏操作的显式空白区发起；在页签或其控件上开始的拖动 MUST NOT 移动窗口。macOS 用户双击该显式空白区时，系统 SHALL 执行窗口的标准缩放或还原操作；双击页签、关闭控件或侧栏操作 MUST NOT 缩放窗口。

#### Scenario: 跨平台相同工作区状态

- **GIVEN** 两个平台具有相同的页签数据和活动页签
- **WHEN** 渲染统一工作区 chrome
- **THEN** 页签顺序、活动状态、连接状态和关闭确认语义 MUST 一致

#### Scenario: 平台特有窗口行为

- **GIVEN** 用户在 macOS 或 iPadOS 使用工作区
- **WHEN** 平台呈现窗口控件、安全区或系统导航入口
- **THEN** 平台可使用原生适配行为，但页签业务规则不得改变

#### Scenario: macOS 在页签上开始拖放

- **GIVEN** macOS 工作区存在至少两个页签
- **WHEN** 用户从页签可见区域开始拖向另一个页签
- **THEN** 页签拖放接收该手势
- **AND** 窗口位置 MUST NOT 因该手势改变

#### Scenario: macOS 双击顶部空白区

- **GIVEN** macOS 主窗口未处于全屏状态
- **WHEN** 用户双击顶部 chrome 的显式空白区
- **THEN** 窗口执行系统标准缩放或还原操作

#### Scenario: macOS 双击页签控件

- **GIVEN** macOS 工作区显示页签、关闭控件或侧栏操作
- **WHEN** 用户双击其中任一控件
- **THEN** 窗口 MUST NOT 缩放或还原
- **AND** 控件保持其既有交互语义
