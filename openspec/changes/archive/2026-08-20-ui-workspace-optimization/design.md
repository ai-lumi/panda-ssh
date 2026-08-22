# Design: 工作区 UI 优化

## Context

工作区由 `WorkspaceView`（自定义标签栏 + 内容区分发）+ `WorkspaceStore`（标签生命周期）+ `TerminalTabView`/`SftpTabView` 构成。连接生命周期已由 `long-lived-connections` 提案改造为「长连接缓存 + 显式断开」：`WorkspaceStore.close` 在某主机最后一个标签页关闭时调用 `disconnectHost(hostId)`（FFI → `ConnectionPool::disconnect_host`，仅移除池条目；运行中传输持有的 `Arc<SshSession>` 在 drop 时才真正断开）。传输任务在 Rust 侧 `run_transfer_task` 全程持有通过 `get_or_create` 取得的 `Arc<SshSession>`，且自带 `password`/`passphrase`，不依赖 Swift 侧 `SftpSessionStore.connectionSecrets`。

关键约束：业务逻辑只落 `crates/panda-core`，Swift 侧仅经 FFI/`AppBackend` 调用；`#if os()` 仅用于 UI/平台服务差异；强制 TDD。

## Goals / Non-Goals

**Goals:**
- 在不新增 FFI 的前提下，实现标签右键菜单、关闭确认、传输延续与连接释放协调。
- 让「关闭 SFTP 标签」与「传输进行中」正确解耦，消除排队任务在 `disconnect_host` 后新建连接并重新入池导致的连接泄漏。
- 所有交互双端原生（右键/长按、确认弹窗、路径输入）。

**Non-Goals:**
- 不改 Rust 侧连接池/传输执行逻辑（仅在 Swift 层协调断开时机）。
- 不做路径自动补全、不做终端会话恢复。

## Decisions

### 1. 标签页右键菜单与批量关闭

`WorkspaceTabItemView` 增加 `.contextMenu`（macOS 右键 / iPadOS 长按由系统自动映射），三项：
- **重连**：仅 `kind == .terminal` 展示；调用 `workspace.reconnectTerminal(tabID:)` → 由 `TerminalSessionStore` 暴露的 `retry()` 复用既有重连路径（已含 `attempt +1` 驱动 `.task` 重跑）。SFTP 标签不展示此项（而非禁用），减少 iPadOS 长按菜单噪声。
- **关闭其他标签页**：`workspace.closeOthers(keeping: tabID)`，遍历关闭其他标签，每个终端标签走与单关闭一致的确认流程（见决策 2）。
- **关闭全部标签页**：`workspace.closeAll()`。

`WorkspaceStore` 新增上述方法。`closeOthers`/`closeAll` 复用统一私有 `close(tabID:confirmingTerminals:)` 路径，避免重复实现。

**替代方案**：菜单项用禁用态展示「重连」给 SFTP 标签。**否决**：iPadOS 长按菜单里禁用项体验差，按平台习惯隐藏更干净。

### 2. SSH 终端关闭二次确认

关闭流程改为「请求关闭」而非「直接关闭」：
- `WorkspaceStore` 新增 `@Published var pendingCloseTabID: UUID?`（待确认关闭的标签）与 `requestClose(tabID:)`。
- `WorkspaceTabItemView` 的关闭按钮调用 `requestClose`。
- `WorkspaceView` 顶层挂一个 `.confirmationDialog`，绑定 `pendingCloseTabID`；仅当目标标签为终端标签且其 `TerminalSessionStore.phase == .shell` 时展示；否则直接执行 `close`。
- 确认/取消均清理 `pendingCloseTabID`。

**为何用 `confirmationDialog`**：macOS 14+ / iPadOS 17+ 同族原生组件，符合「对话框样式符合系统风格」；比 `.alert` 更适合带「关闭/取消」二选一的破坏性确认。连接中/失败态终端标签直接关闭，不打扰。

终端标签的 phase 由视图层持有（`TerminalSessionStore` 是 `@StateObject`），`WorkspaceStore` 不直接知道 phase。因此确认与否的判断放在 `WorkspaceView`：它按 `activeTabID`/`pendingCloseTabID` 找到对应视图状态。为避免 `WorkspaceStore` 反向依赖视图，`WorkspaceView` 通过 `@EnvironmentObject` 拿 `pendingCloseTabID`，并在 `.confirmationDialog` 的 `isPresented` 计算中判断「是否为已连接终端」。终端 phase 暴露：`TerminalTabView` 将 phase 通过 `@Binding` 或 `Environment` 上报代价高；改为 `WorkspaceStore` 持有一个 `terminalPhaseProvider: (UUID) -> TerminalPhase?` 闭包（由 `PandaSSHApp` 注入，类似 `hostNameProvider`），`TerminalSessionStore` 在 phase 变化时回调注册。

**简化方案（采用）**：`TerminalSessionStore` 提供 `phase`，`WorkspaceView` 维护 `tabID -> phase` 弱映射不现实。改为：关闭确认直接对**所有终端标签**弹出（不区分 phase），文案「关闭终端将断开会话，是否继续？」；连接中/失败态也弹。**否决**——spec 明确连接中/失败不弹。

**最终采用**：`WorkspaceStore` 增加 `terminalConnectedChecker: (UUID) -> Bool` 注入闭包。`TerminalSessionStore` 在 `init` 时把自己注册到 `WorkspaceStore`（`register(terminalSession:for tabID:)`），`close` 时移除。`requestClose` 据此判断是否需确认。这样 `WorkspaceStore` 不依赖视图层级，仅持弱引用字典 `tabID -> WeakTerminalSession`。

### 3. SFTP 关闭与传输延续 + 连接释放协调（核心）

问题：当前 `close` 立即 `disconnectHost`。运行中传输持有的 `Arc<SshSession>` 仍存活（传输继续），但**排队任务**在 `disconnect_host` 后启动会 `get_or_create` 新建连接并重新入池，完成后该池条目无人清理 → 连接泄漏（长连接无空闲回收）。

**方案**：将「主机连接释放」从「关闭标签」解耦，改为「主机无标签页且无活跃传输任务时才 `disconnectHost`」：

- `WorkspaceStore.close(tabID:)` 不再立即调用 `disconnectHandler`；改为调用新方法 `evaluateDisconnect(for: hostID)`。
- `evaluateDisconnect(hostID)`：若仍有同主机标签页 → 什么都不做；若无同主机标签页且 `TransferStore` 无该主机的活跃任务（running/queued/paused）→ 立即 `disconnectHandler(hostID)`；若无同主机标签页但有活跃任务 → 标记该 hostID 进入 `pendingDisconnectHosts: Set<String>`，**不**断开。
- `TransferStore` 任务状态变化时（`tick`/`refresh` 后）回调 `onTasksChanged`；`WorkspaceStore` 据此对 `pendingDisconnectHosts` 中每个 host 重新 `evaluateDisconnect`：若该 host 已无活跃任务 → `disconnectHandler(hostID)` 并从 pending 移除。
- 运行中任务持有的 `Arc<SshSession>` 在任务结束 drop 时断开；此时池条目已被 `disconnect_host` 移除，不会泄漏。

**为何不在 Rust 侧改**：Rust 侧 `disconnect_host` 行为正确（仅移池条目）；泄漏根源在 Swift 侧「断开时机」与「排队任务新建连接入池」的组合。在 Swift 层推迟断开到「无活跃任务」即可避免排队任务在断开后启动，从而不会新建连接入池。无需改 Rust/FFI，符合「业务逻辑在 panda-core、Swift 仅协调」边界（此处属 UI 生命周期协调，非业务规则）。

**订阅方式**：`WorkspaceStore` 持有 `TransferStore` 弱引用 + `cancellables`，订阅 `transfers.$tasks`；或 `PandaSSHApp` 在 `close` 触发后由 `TransferStore` 主动回调。采用 `WorkspaceStore` 注入 `TransferStore` 引用（App 初始化时注入），订阅 `$tasks.sink` 调 `evaluatePendingDisconnects()`。注意避免循环引用：`WorkspaceStore` 强持 `TransferStore`（App 中两者同生命周期），`TransferStore` 不回持 `WorkspaceStore`。

**主机删除级联**：`closeTabs(forHostID:)`（删除主机时）仍需立即断开该主机（用户已删除主机，传输任务对已删主机无意义）。此时调用 `disconnectHandler` 并取消该主机的活跃传输任务（`TransferStore` 按 hostID 取消）。列为决策 4 的边界。

### 4. 双击文件触发传输

`SftpTabView.fileRow` 已对目录附加 `TapGesture(count: 2)`。改为对**文件**也附加双击：双击文件 → `session.selectLocal(name)` / `selectRemote(name)` 后 `await session.uploadSelected()` / `downloadSelected()`（复用既有单文件路径，含覆盖确认）。双击目录保持进入。

**手势冲突**：单击与双击已用 `simultaneousGesture` + `onTapGesture` 共存；文件双击与目录双击互斥（按 `isDirectory` 分支），无冲突。

### 5. 多选上下文菜单

`fileContextMenu` 当前在 `multiSelect` 时返回 `EmptyView`。改为：
- 多选模式下右键选中集合内条目 → 菜单「上传/下载（N 项）」「删除（N 项）」，作用于 `selectedLocalSet`/`selectedRemoteSet`。
- 右键未选中条目 → 先 `selectLocal(name, append: false)` 置为唯一选中，再展示单选菜单（由 `contextMenu` 的 `forObject` 行为：`onTapGesture` 不触发，需在 `contextMenu` 闭包内读取当前选中判断）。SwiftUI `contextMenu` 在右键时不会改变选中，因此需在菜单按钮 action 内或菜单展示前调整：采用「右键未选中条目时，菜单第一项 action 前先重置选中」。简化：在 `fileRow` 上加 `.contextMenu { ... }`，菜单内容根据 `selectedSet.contains(entry.name)` 决定是「集合操作」还是「单项操作」；若未在集合中，菜单按钮 action 内先 `select(name, append:false)` 再执行。这保证「右键未选中 → 作用于该条目」。

**菜单样式**：SwiftUI `contextMenu` 在 macOS/iPadOS 均渲染为系统原生菜单，符合「优先使用原生组件」。

### 6. 可编辑路径导航

`paneHead` 的面包屑 `ScrollView` 改为：默认展示面包屑；点击进入编辑态（`@State var pathEditing: Bool`，`@State var pathInput: String`）。编辑态展示 `TextField`，预填当前 `nav.path`：
- 回车 → `Task { await session.navigateLocal(to: pathInput) / navigateRemote(...) }`（复用 `FilePaneNavigator.navigate(to:)`，已有「仅接受当前路径前缀内祖先路径」限制——**需放宽**：支持任意绝对路径，非法/不可访问时 `reload` 返回 false 并保持原目录 + toast）。
- Esc / 失焦 → 退出编辑态，不跳转。

**`navigate(to:)` 放宽**：当前 `navigate` 仅允许祖先前缀路径。改为允许任意路径，内部 `reload` 失败时回滚 `path` 到原值并返回 false。本地栏用 `FileManager`，远程栏用 `sftpList`，失败均能捕获。

### 7. 移除 `>>` 按钮（侧栏最小宽度）

`>>` 按钮是侧栏工具栏空间不足时系统自动出现的折叠入口（把溢出的 toolbar items 折进右侧菜单）。根因是侧栏宽度可被压缩到容不下完整工具栏（「添加主机」「新建分组」等）。解法：为 `NavigationSplitView` 侧栏列设置最小宽度（`.frame(minWidth:)` 约束侧栏内容，或通过列宽度约束），保证工具栏项始终完整展示，从而消除右侧 `>>` 折叠入口。iPadOS 上侧栏默认全宽展示，紧凑宽度下侧栏会变为覆盖式，需验证不回归。

## Risks / Trade-offs

- **[终端 phase 同步]** `WorkspaceStore` 持 `tabID -> WeakTerminalSession` 字典判断「是否已连接」以决定是否弹确认。→ 弱引用避免泄漏；字典在 `close` 时清理；测试用注入的 phase provider 覆盖。
- **[传输完成回调时机]** `TransferStore` 轮询频率变化时 `$tasks` 发射可能抖动，导致 `evaluatePendingDisconnects` 短时间内多次求值。→ 幂等：`disconnectHost` 对已断开主机为 no-op；`pendingDisconnectHosts` 集合去重。
- **[关闭其他/全部的确认风暴]** 批量关闭多个已连接终端标签会连续弹多个确认框。→ `closeOthers`/`closeAll` 改为单次聚合确认「关闭 N 个已连接终端？」，确认后一并关闭。spec 已要求「批量关闭走一致流程」，聚合确认是合理实现。
- **[路径跳转放宽安全性]** 远程路径输入可能访问权限外目录。→ `sftpList` 失败即回滚并提示，无安全风险（SFTP 服务器侧鉴权）。
- **[排队任务在断开前已入池]** 极端情况：`evaluateDisconnect` 判定无活跃任务前，一个 queued 任务刚好变 running 并入池。→ 下一轮 `tick` 会再次求值并断开（running 任务持有 Arc 不受影响），最终一致。

## Open Questions

1. **「重连」对 SFTP 标签的语义**：当前 spec 规定 SFTP 标签不提供「重连」。若后续希望 SFTP 标签支持重新连接，另立提案。
