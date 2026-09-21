## MODIFIED Requirements

### Requirement: 终端窗口调整

系统 SHALL 支持在终端会话存活期间动态调整窗口尺寸。客户端窗口尺寸变化时 MUST 向服务端发送 `window-change` 请求，携带新的列数和行数。

若终端视图在 shell 连接建立前已获得有效行列数，系统 MUST 保留最新尺寸，并在该 shell 连接可用时立即向服务端发送一次 `window-change`。此同步 MUST 使用最新的已知尺寸，且不得依赖用户再次缩放窗口。

尺寸上报采用去抖策略：会话建立后的首次尺寸 MUST 立即上报；此后的连续尺寸变化（如侧栏显隐动画、窗口拖拽产生的逐帧回调）SHALL 做约 150ms 去抖，仅在尺寸稳定后上报最终值，MUST NOT 逐帧发送——逐帧 `window-change` 会让远端 shell 遭遇 SIGWINCH 风暴，其重绘序列与本地 reflow 交错时会把光标推到屏幕中部（终端上方出现大片空白）。连接可用前遗留的去抖任务 MUST NOT 在连接同步后重复发送过期尺寸。

本地终端视图的行列适配（SwiftTerm resize/reflow）SHALL 保持实时，不受上报去抖影响。

#### Scenario: 客户端调整窗口尺寸

- **WHEN** 用户拖拽调整终端窗口大小（例如从 80×24 变为 120×40）
- **THEN** 服务端终端收到新的尺寸参数，应用程序（如 vim、top）正确适配

#### Scenario: 窗口尺寸变化频繁

- **WHEN** 用户快速拖拽调整窗口，短时间内产生多次尺寸变化事件
- **THEN** 最新尺寸 MUST 最终被服务端正确接收，SHALL NOT 丢失最后一次调整
- **AND** 连续变化期间 SHALL 去抖上报，不逐帧发送 `window-change`

#### Scenario: 初次布局早于 shell 连接

- **GIVEN** 终端视图已完成有效行列数的初次布局，但 shell 连接尚未建立
- **WHEN** shell 连接随后可用，且用户没有缩放窗口
- **THEN** 服务端终端立即收到该最新行列数的一次 `window-change`，全屏程序以正确初始尺寸启动
