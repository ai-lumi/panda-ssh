## Purpose

定义 macOS 端键盘快捷键行为：CMD+W 关闭当前活动页签（焦点感知），CMD+Q 两次按下退出应用（防误触保护）。

## ADDED Requirements

### Requirement: CMD+W 焦点感知关闭当前页签

macOS 端 SHALL 响应 CMD+W 快捷键关闭当前活动页签，但仅当键盘焦点位于页签区域时生效。焦点不在页签区域时 SHALL 不执行任何关闭操作，MUST NOT 影响当前活动页签。CMD+W 触发的关闭 SHALL 走与点击页签关闭按钮完全一致的流程，包括已连接终端标签页的二次确认。

#### Scenario: 焦点在页签区域时 CMD+W 关闭当前页签

- **GIVEN** 工作区有一个或多个活动页签，且键盘焦点位于页签区域
- **WHEN** 用户按下 CMD+W
- **THEN** 系统关闭当前活动页签，行为与点击该页签的关闭按钮一致

#### Scenario: CMD+W 关闭已连接终端触发二次确认

- **GIVEN** 当前活动页签为已连接状态的终端标签页，焦点在页签区域
- **WHEN** 用户按下 CMD+W
- **THEN** 系统弹出与点击关闭按钮一致的原生确认对话框
- **AND** 用户确认后才关闭并断开会话

#### Scenario: 焦点不在页签区域时 CMD+W 无响应

- **GIVEN** 键盘焦点位于侧栏、主机详情、SFTP 文件列表或终端内容区
- **WHEN** 用户按下 CMD+W
- **THEN** 系统不关闭任何页签，当前活动页签保持不变

#### Scenario: 无活动页签时 CMD+W 无响应

- **GIVEN** 工作区没有任何活动页签
- **WHEN** 用户按下 CMD+W
- **THEN** 系统不执行任何操作

### Requirement: CMD+Q 两次按下退出保护

macOS 端 SHALL 拦截 CMD+Q 快捷键，首次按下时不退出应用，而是显示一个短暂的「再按一次退出」视觉提示。在提示可见期间再次按下 CMD+Q SHALL 真正退出应用。提示超时消失后，下一次 CMD+Q 重新走首次按下流程。

#### Scenario: 首次 CMD+Q 显示退出提示

- **GIVEN** 应用处于前台运行状态
- **WHEN** 用户首次按下 CMD+Q
- **THEN** 应用不退出
- **AND** 窗口内显示「再按一次退出」的视觉提示

#### Scenario: 提示可见时再次 CMD+Q 退出

- **GIVEN** 「再按一次退出」提示当前可见
- **WHEN** 用户再次按下 CMD+Q
- **THEN** 应用正常退出，释放所有会话与连接

#### Scenario: 提示超时后重置

- **GIVEN** 「再按一次退出」提示已显示
- **WHEN** 用户在提示超时前未再次按下 CMD+Q
- **THEN** 提示自动消失
- **AND** 下一次 CMD+Q 重新显示提示，不退出应用

#### Scenario: CMD+Q 提示不阻塞其他操作

- **GIVEN** 「再按一次退出」提示当前可见
- **WHEN** 用户执行除 CMD+Q 以外的任何操作
- **THEN** 提示保持可见且不影响该操作的正常执行

### Requirement: 快捷键仅限 macOS 端

CMD+W 页签关闭与 CMD+Q 退出保护的快捷键行为 SHALL 仅在 macOS 端实现和生效。iPadOS 端 SHALL NOT 实现本次定义的快捷键行为。

#### Scenario: macOS 端快捷键生效

- **WHEN** 用户在 macOS 端按下 CMD+W 或 CMD+Q
- **THEN** 系统按上述规格响应

#### Scenario: iPadOS 端不实现快捷键

- **WHEN** 用户在 iPadOS 端使用外接键盘按下 CMD+W 或 CMD+Q
- **THEN** 系统按 iPadOS 既有行为处理，不触发本次定义的关闭页签或退出保护逻辑
