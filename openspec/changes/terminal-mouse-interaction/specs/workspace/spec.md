## ADDED Requirements

### Requirement: 终端内容区右键上下文菜单

终端标签页的内容区 SHALL 支持右键弹出原生上下文菜单：macOS 端通过鼠标右键触发；iPadOS 端 SHALL 同时支持触摸长按与外接鼠标右键（蓝牙 / USB 鼠标，含 Universal Control 从 Mac 转入的鼠标）触发。菜单条目 SHALL 至少包含：复制、粘贴、粘贴并回车、全选、清屏、重置终端、复制并粘贴、重连、关闭标签页。条目可用性 MUST 根据当前会话阶段与终端状态动态启用 / 禁用，禁用条目 SHALL 保留在菜单中但不可点击。两端的菜单条目集合与启用规则 SHALL 一致，差异只落在触发手势与原生菜单实现（`NSMenu` vs `UIEditMenuInteraction`）。

#### Scenario: 无选中状态打开右键菜单

- **GIVEN** 终端标签页处于 shell 阶段，且终端内容区当前无选中文本
- **WHEN** 用户在终端内容区右键（macOS）、长按（iPadOS 触摸）或在 iPadOS 上外接鼠标右键点击
- **THEN** 弹出上下文菜单，「复制」「复制并粘贴」为禁用态，「粘贴」「粘贴并回车」「全选」「清屏」「重置终端」「重连」「关闭标签页」为可用态

#### Scenario: 有选中状态打开右键菜单

- **GIVEN** 终端标签页处于 shell 阶段，且终端内容区存在非空选中文本
- **WHEN** 用户在终端内容区右键
- **THEN** 弹出上下文菜单，「复制」「复制并粘贴」为可用态

#### Scenario: 连接失败阶段菜单条目禁用

- **GIVEN** 终端标签页处于 failed 阶段
- **WHEN** 用户右键终端内容区
- **THEN** 菜单中「粘贴」「粘贴并回车」「清屏」「重置终端」「复制并粘贴」为禁用态，「重连」「关闭标签页」为可用态

#### Scenario: 连接中阶段菜单条目禁用

- **GIVEN** 终端标签页处于 connecting 阶段
- **WHEN** 用户右键终端内容区
- **THEN** 菜单中除「关闭标签页」外其它条目为禁用态

#### Scenario: 执行复制

- **GIVEN** 终端内容区有非空选中文本
- **WHEN** 用户在右键菜单选择「复制」
- **THEN** 选中文本被写入系统剪贴板，终端内容区保持选中态不变

#### Scenario: 执行粘贴

- **GIVEN** 系统剪贴板有文本，终端标签页处于 shell 阶段
- **WHEN** 用户在右键菜单选择「粘贴」
- **THEN** 系统剪贴板文本作为输入写入当前 SSH shell 通道，SHALL NOT 自动追加换行符

#### Scenario: 执行粘贴并回车

- **GIVEN** 系统剪贴板有文本，终端标签页处于 shell 阶段
- **WHEN** 用户在右键菜单选择「粘贴并回车」
- **THEN** 系统剪贴板文本写入 SSH shell 通道，随后 MUST 追加一个换行符（LF, U+000A）

#### Scenario: 执行全选

- **WHEN** 用户在右键菜单选择「全选」
- **THEN** 终端可视缓冲区全部内容被选中

#### Scenario: 执行清屏

- **GIVEN** 终端标签页处于 shell 阶段
- **WHEN** 用户在右键菜单选择「清屏」
- **THEN** 系统 SHALL 通过当前 SSH shell 通道发送 `clear` 命令字节流到远端，远端 shell 负责清屏，SHALL NOT 在客户端本地清空滚动历史

#### Scenario: 执行重置终端

- **WHEN** 用户在右键菜单选择「重置终端」
- **THEN** 系统在客户端清空终端滚动缓冲，并向当前 SSH shell 通道发送 RIS 控制序列（ESC c, U+001B U+0063）

#### Scenario: 执行复制并粘贴

- **GIVEN** 终端内容区有非空选中文本，终端标签页处于 shell 阶段
- **WHEN** 用户在右键菜单选择「复制并粘贴」
- **THEN** 选中文本被写入系统剪贴板，随后系统剪贴板文本被写入当前 SSH shell 通道，SHALL NOT 追加换行符

#### Scenario: 执行重连

- **GIVEN** 终端标签页处于 failed 阶段
- **WHEN** 用户在右键菜单选择「重连」
- **THEN** 系统调用既有终端会话重连流程（复用上次连接参数），会话阶段回到 connecting

#### Scenario: 执行关闭标签页

- **GIVEN** 终端标签页已连接（处于 shell 阶段）
- **WHEN** 用户在右键菜单选择「关闭标签页」
- **THEN** 系统 SHALL 触发既有「SSH 终端标签页关闭二次确认」流程，确认后才关闭

#### Scenario: 右键命中链接时显示链接条目

- **GIVEN** 右键点击位置命中 OSC 8 链接或 URL 文本
- **WHEN** 用户右键终端内容区
- **THEN** 菜单 SHALL 在常规条目之上额外显示「复制链接地址」与「打开链接」两个条目；不命中时 SHALL NOT 显示这两个条目

### Requirement: 终端中键粘贴选中文本

macOS 端终端标签页 SHALL 支持「中键粘贴选中文本」语义：用户左键选中文本松开后，系统在客户端内部维护一份「终端 PRIMARY selection」缓冲；用户中键点击终端内容区时，把该缓冲中文本作为输入字节流写入当前 SSH shell 通道。该缓冲 SHALL NOT 写入系统剪贴板（`NSPasteboard.general`），避免与 Cmd+C / Cmd+V 语义冲突。iPadOS 端 SHALL NOT 启用此能力——**限制根因**：SwiftTerm iOS 端不区分鼠标按键，外接鼠标（蓝牙 / USB）与 Universal Control 从 Mac 转入的鼠标的中键事件不会被 SwiftTerm iOS 路径捕获，因此 iPad 上即使外接鼠标也无法触发中键粘贴，该限制为已知边界，未来 SwiftTerm 升级或独立提案再解锁。

#### Scenario: 选中后中键粘贴

- **GIVEN** 终端标签页处于 shell 阶段
- **WHEN** 用户左键拖拽选中文本并松开，随后中键点击终端内容区
- **THEN** 系统把最近一次选中的文本写入当前 SSH shell 通道，SHALL NOT 追加换行符

#### Scenario: 未选中时中键无操作

- **GIVEN** 终端 PRIMARY selection 缓冲为空（从未选中文本或选中为空字符串）
- **WHEN** 用户中键点击终端内容区
- **THEN** 系统 SHALL NOT 向 SSH shell 通道写入任何字节，SHALL NOT 弹出菜单或对话框

#### Scenario: 中键粘贴不污染系统剪贴板

- **GIVEN** 用户在终端选中文本后，系统剪贴板当前内容为 X
- **WHEN** 用户中键点击终端内容区完成粘贴
- **THEN** 系统剪贴板内容 MUST 仍为 X，SHALL NOT 被替换为选中文本

#### Scenario: 会话非 shell 阶段时中键无操作

- **GIVEN** 终端标签页处于 connecting 或 failed 阶段
- **WHEN** 用户中键点击终端内容区
- **THEN** 系统 SHALL NOT 向任何通道写入字节

#### Scenario: iPadOS 不启用中键粘贴

- **GIVEN** iPadOS 平台的终端标签页（无论是否外接鼠标或 Universal Control 转入鼠标）
- **WHEN** 用户在终端内容区中键点击或做任何手势
- **THEN** 系统 SHALL NOT 触发中键粘贴相关行为，SHALL NOT 维护终端 PRIMARY selection 缓冲

### Requirement: 终端选中即缓存 PRIMARY selection

macOS 端终端内容区在用户完成文本选择（`mouseUp` 时存在非空选中文本）后，系统 SHALL 把选中文本写入客户端内部维护的「终端 PRIMARY selection」缓冲，覆盖前一次缓冲内容。该缓冲独立于系统剪贴板，SHALL NOT 在写入时触发系统剪贴板变更通知。iPadOS 端 SHALL NOT 维护此缓冲（中键粘贴能力不启用，无消费方）。

> **已知边界**：读取选中文本以填充缓冲时，受 SwiftTerm `selection` 为 `internal` 限制，实现采用「瞬态 `copy` + 恢复剪贴板」模式（详见 [design.md 已知边界](../../design.md)）。缓冲本身为纯内存 `String`，不写系统剪贴板；但读取过程存在瞬态写入窗口（微秒级，结束后恢复原值）。此为实现 SwiftTerm 公共 API 缺失的必要妥协，未来 SwiftTerm 暴露公共选中文本入口后可消除。

#### Scenario: 选中文本更新 PRIMARY 缓冲

- **GIVEN** 终端标签页处于 shell 阶段
- **WHEN** 用户左键拖拽选中文本并松开鼠标
- **THEN** 终端 PRIMARY selection 缓冲被更新为当前选中文本，覆盖前一次缓冲内容

#### Scenario: 空选中不更新 PRIMARY 缓冲

- **GIVEN** 终端 PRIMARY selection 缓冲已存有文本 A
- **WHEN** 用户左键点击终端空白处使选中为空字符串
- **THEN** 终端 PRIMARY selection 缓冲 MUST 保持为 A，SHALL NOT 被替换为空字符串

#### Scenario: PRIMARY 缓冲独立于系统剪贴板

- **GIVEN** 用户在终端选中文本 B，系统剪贴板当前内容为 C
- **WHEN** 文本 B 被写入终端 PRIMARY selection 缓冲
- **THEN** 系统剪贴板内容 MUST 仍为 C，SHALL NOT 变为 B
