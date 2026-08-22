# Tasks: 工作区 UI 优化

> 严格 TDD：每个实现子任务前先写会失败的 XCTest（Swift 侧可测逻辑）。Rust 侧本提案无逻辑变更，仅回归。测试目标位于 Swift 测试 target（`apple/Tests` 下），覆盖 `WorkspaceStore` / `TransferStore` / `SftpSessionStore` / `FilePaneNavigator` 可测逻辑。

## 1. 标签页右键菜单与批量关闭（item 2）

- [x] 1.1 测试：`WorkspaceStore.closeOthers(keeping:)` 关闭除目标外全部标签、保留目标为活动标签、活动标签切换到目标；对被关闭主机的最后一个标签触发 `disconnectHandler`
- [x] 1.2 测试：`WorkspaceStore.closeAll()` 关闭全部标签、`activeTabID` 归 nil、各主机无残留标签时各自触发 `disconnectHandler`
- [x] 1.3 测试：`WorkspaceStore.reconnectTerminal(tabID:)` 对终端标签调用注入的 `reconnectHandler(tabID)`；对 SFTP 标签为 no-op
- [x] 1.4 实现：`WorkspaceStore` 新增 `closeOthers(keeping:)` / `closeAll()` / `reconnectTerminal(tabID:)`，统一走私有 `close(tabID:)` 路径（含决策 3 的 `evaluateDisconnect`）
- [x] 1.5 UI：`WorkspaceTabItemView` 挂 `.contextMenu`——「重连」（仅 `kind == .terminal`）、「关闭其他标签页」、「关闭全部标签页」

## 2. SSH 终端关闭二次确认（item 3）

- [x] 2.1 测试：`requestClose(tabID:)` 对「已连接」终端标签设置 `pendingCloseTabID` 且不立即关闭；对连接中/失败态终端标签与 SFTP 标签直接关闭
- [x] 2.2 测试：`confirmClose()` 关闭 pending 标签并清理 `pendingCloseTabID`；`cancelClose()` 仅清理 `pendingCloseTabID` 保留标签
- [x] 2.3 实现：`WorkspaceStore` 新增 `pendingCloseTabID` / `requestClose` / `confirmClose` / `cancelClose`，以及 `terminalConnectedChecker: (UUID) -> Bool` 注入；`TerminalSessionStore` 在 init 注册、close 时注销（弱引用映射）
- [x] 2.4 UI：`WorkspaceView` 顶层挂 `.confirmationDialog`（绑定 `pendingCloseTabID`，文案「关闭终端将断开会话，是否继续？」）；关闭按钮改调 `requestClose`
- [x] 2.5 UI：批量关闭（`closeOthers`/`closeAll`）含多个已连接终端时，聚合为单次确认「关闭 N 个已连接终端会话？」

## 3. SFTP 关闭与传输延续 + 连接释放协调（item 4 核心）

- [x] 3.1 测试：关闭某主机最后一个标签页且该主机有活跃传输任务（注入 mock `TransferStore` 含 running/queued/paused 任务）→ MUST NOT 调用 `disconnectHandler`，且该 hostID 进入 `pendingDisconnectHosts`
- [x] 3.2 测试：关闭某主机最后一个标签页且无活跃传输任务 → 立即调用 `disconnectHandler(hostID)`，不进入 pending
- [x] 3.3 测试：`TransferStore.$tasks` 变化使 pending 主机不再有活跃任务 → 调用 `disconnectHandler` 并从 pending 移除；仍有活跃任务 → 保持 pending
- [x] 3.4 测试：某主机仍有终端标签打开时，其 SFTP 标签关闭 + 传输完成 → MUST NOT 调用 `disconnectHandler`
- [x] 3.5 测试：关闭 SFTP 标签页 MUST NOT 触发 `TransferStore.cancel` 该主机任何任务；该主机任务状态保持不变（验证传输延续）
- [x] 3.6 实现：`WorkspaceStore` 注入 `TransferStore` 引用 + `cancellables` 订阅 `$tasks`；新增 `evaluateDisconnect(hostID:)` / `evaluatePendingDisconnects()` / `pendingDisconnectHosts`
- [x] 3.7 实现：`close(tabID:)` 移除立即 `disconnectHandler` 调用，改为 `evaluateDisconnect`；`closeTabs(forHostID:)` 保持立即断开并取消该主机活跃传输任务（主机删除级联）
- [x] 3.8 UI/接线：`PandaSSHApp` 注入 `TransferStore` 到 `WorkspaceStore`；`SftpTabView.onDisappear { session.disconnect() }` 保留（仅清理凭据），不断开主机连接
- [x] 3.9 验证 Rust 侧无逻辑变更：`cargo test` 回归全绿（确认运行中传输持有 `Arc<SshSession>` 不受 `disconnect_host` 影响）

## 4. SFTP 双击文件触发传输（item 6）

- [x] 4.1 测试：双击本地文件条目 → `SftpSessionStore` 创建恰好 1 个上传任务（断言 `transfers.add` 调用一次、方向 upload）；双击远程文件 → 恰好 1 个下载任务；双击目录 → 调用 `enterLocal/enterRemote` 且 `transfers.add` 调用 0 次
- [x] 4.2 实现：`SftpTabView.fileRow` 对 `!entry.isDirectory` 分支附加 `TapGesture(count: 2)`，复用 `session.uploadSelected()` / `downloadSelected()`；目录双击保持既有进入逻辑

## 5. SFTP 多选上下文菜单（item 5）

- [x] 5.1 测试：`fileContextMenu` 在多选模式下右键选中集合内条目 → 菜单项文案含数量（如「上传 N 项」），action 作用于整个选中集合；右键未选中条目 → action 先将该条目置为唯一选中再执行
- [x] 5.2 实现：`SftpTabView.fileContextMenu` 移除 `multiSelect { EmptyView }` 分支，按 `selectedSet.contains(entry.name)` 决定集合操作/单项操作；未选中时 action 内先 `selectLocal/Remote(name, append:false)`
- [x] 5.3 验证：菜单由 SwiftUI `contextMenu` 渲染（macOS 右键 / iPadOS 长按原生样式），无自定义弹层

## 6. SFTP 路径导航可输入跳转（item 7）

- [x] 6.1 测试：`FilePaneNavigator.navigate(to:)` 放宽——任意绝对路径且 `list` 成功时跳转并返回 true；`list` 失败时回滚 `path` 到原值、`lastError` 置位、返回 false（本地与远程 source 各覆盖）
- [x] 6.2 测试：路径输入态——回车触发 `navigate(to:)` 成功跳转；Esc/失焦回到面包屑态且当前目录不变；非法路径保持原目录并 toast 提示
- [x] 6.3 实现：`FilePaneNavigator.navigate(to:)` 移除「仅祖先前缀」限制，改为 try reload、失败回滚 `path`
- [x] 6.4 UI：`SftpTabView.paneHead` 面包屑区域点击切换为 `TextField`（`@State pathEditing` / `pathInput`），回车提交、Esc/失焦取消；本地与远程面板独立状态

## 7. 移除主窗口 `>>` 按钮（item 1）

- [x] 7.1 实现：为 `NavigationSplitView` 侧栏列设置最小宽度（`minWidth` 约束），保证工具栏项（添加主机、新建分组）完整展示，消除空间不足触发的 `>>` 折叠按钮
- [ ] 7.2 验收：macOS 窗口缩到最小宽度时工具栏项仍完整可见、无 `>>`；iPadOS 紧凑宽度下不回归

## 8. 构建与验收

- [x] 8.1 `cargo test` 全绿（回归，预期无 Rust 改动）
- [ ] 8.2 Swift 测试 target 全绿（`xcodebuild test`，macOS）
- [ ] 8.3 `apple/Scripts/build-rust.sh` → `xcodegen` → macOS/iOS 双端 `xcodebuild build` 通过
- [ ] 8.4 手动验收 7 项场景：无 `>>` 按钮、标签右键三项、终端关闭确认、SFTP 关闭传输延续并最终释放连接、文件多选右键、双击文件传输、路径输入跳转

## 9. Bug 修复：非活动终端标签关闭确认 + 多选删除

### 9.1 非活动终端标签关闭确认缺失（item 2/3 回归）

- [x] 9.1.1 测试：`WorkspaceStore.markTerminalConnected(tabID:)` 后,默认 `terminalConnectedChecker` 返回 true;`markTerminalDisconnected` 后返回 false
- [x] 9.1.2 测试：标记终端已连接后,`requestCloseOthers` 设置 `pendingBatchClose`(即使终端视图已因切到 SFTP 而销毁)
- [x] 9.1.3 测试：`close(tabID:)` 清除 `connectedTerminalTabs`,防止幽灵确认
- [x] 9.1.4 测试：`requestClose` 在 `markTerminalConnected` 后弹确认,未标记时直接关闭
- [x] 9.1.5 实现：`WorkspaceStore` 新增 `connectedTerminalTabs: Set<UUID>`,独立于视图生命周期追踪连接态;默认 `terminalConnectedChecker` 改为读此集合
- [x] 9.1.6 实现：`TerminalTabView` `.onChange(of: session.phase)` 在 `.shell` 时调 `markTerminalConnected`;`.onDisappear` 不再注销(注销移至 `close(tabID:)`)

### 9.2 多选右键删除未处理整个选中集合（item 5 回归）

- [x] 9.2.1 测试：`contextDelete(entry:local:)` 在多选右键选中集合内条目时删除整个集合(2 项);右键未选中条目时先置为唯一选中再删除(1 项);单选时仅删除该条目
- [x] 9.2.2 实现：`SftpSessionStore` 提取 `deleteLocalCore`/`deleteRemoteCore`(不刷新面板),新增 `deleteLocalBatch`/`deleteRemoteBatch`(逐个删除后统一刷新一次),新增 `contextDelete(entry:local:)` 镜像 `contextUpload` 模式
- [x] 9.2.3 实现：`SftpTabView.deleteCandidate` 改为 `(names: [String], local: Bool)`;`fileContextMenu` 删除按钮多选时传整个选中集合、标签含数量;删除确认弹窗支持批量文案与批量执行
