## Context

当前 macOS 主窗口使用 SwiftUI 构建，页签栏通过 `MainWindowChrome` 装配在系统工具栏位置。页签关闭逻辑已完整实现（包括已连接终端的二次确认），但缺少键盘快捷键触发入口。应用退出使用系统默认的 CMD+Q 行为，无任何保护。

SwiftUI 在 macOS 14+ 提供 `.onKeyPress(keys:phases:action:)` 修饰符，可捕获特定按键组合。这是实现键盘快捷键的首选 API。

## Goals / Non-Goals

**Goals:**
- CMD+W 在页签焦点区域关闭当前活动页签，复用既有关闭流程
- CMD+Q 两次按下退出，防止误触导致会话丢失
- 焦点感知：CMD+W 仅在页签区域持有焦点时生效

**Non-Goals:**
- 不实现更多快捷键（CMD+Shift+W、CMD+T 等）
- 不改变 iPadOS 键盘行为
- 不引入第三方键盘事件库

## Decisions

### 决策 1：使用 `.onKeyPress` 而非 `.keyboardShortcut`

**选择**：在页签容器 View 上使用 `.onKeyPress(keys: [.init("w")], phases: .down)` 捕获 CMD+W；在主窗口根 View 上使用同样的方式捕获 CMD+Q。

**理由**：`.keyboardShortcut` 绑定在 `Button` 上，无法做焦点条件判断。`.onKeyPress` 可在 View 层级精确控制按键响应，且支持通过 View 层级顺序实现焦点感知——页签区域注册的 CMD+W 在焦点位于页签时消费事件，阻止冒泡到其他层。

**替代方案**：使用 `NSEvent.addLocalMonitorForEvents` 全局拦截。缺点是脱离 SwiftUI 视图层级，难以判断焦点状态，且需要 AppKit 桥接，增加复杂度。

### 决策 2：CMD+W 焦点感知通过 View 层级实现

**选择**：在页签栏容器 View 上注册 CMD+W 的 `.onKeyPress`。SwiftUI 的 `.onKeyPress` 仅在当前 View 或其子 View 持有焦点时触发。因此当焦点在侧栏、SFTP 文件列表或终端内容区时，页签栏的 `.onKeyPress` 不会被调用，自然实现「焦点不在页签时不响应」。

**理由**：利用 SwiftUI 已有的焦点机制，无需手动维护焦点状态变量，代码简洁且与系统行为一致。

### 决策 3：CMD+Q 使用 2 秒确认窗口与一次性停机协调器

**选择**：在主窗口根 View 维护带 2 秒超时的待退出状态。首次 CMD+Q 仅显示 toast；第二次有效按键调用一次性应用停机协调器。协调器按固定顺序停止新任务登记、向全部在途任务发出取消、关闭全部终端与 SFTP 连接，完成本地清理调用后才请求 `NSApplication.shared.terminate(nil)`。不显示任务审查或额外确认。

**理由**：进程终止本身不是任务取消与连接释放的可验证证据。集中协调器保留无确认直接退出的交互，同时让取消、关闭、幂等和“结果未知、不重放”具有明确测试边界。超时仍可由 `Task` 实现，并须可注入时钟或等价机制测试边界。

**替代方案**：第二次按键直接调用 `NSApplication.shared.terminate(nil)`。拒绝：无法证明在途任务已收到取消、连接关闭按所有者隔离，且会把远端执行状态不明误当作正常释放。

### 决策 4：CMD+Q 拦截点在主窗口根 View

**选择**：CMD+Q 的 `.onKeyPress` 注册在主窗口最外层 View（`MainWindowChrome` 或其根容器），确保窗口任意位置按下均能捕获。

**理由**：CMD+Q 需要全局响应，注册在最外层保证无论焦点在何处都能拦截。`.onKeyPress` 在 View 层级中由内向外传播，最外层的注册确保兜底捕获。

### 决策 5：退出提示使用 Toast 样式

**选择**：在窗口底部中央显示一个半透明圆角提示条「再按一次退出」，2 秒后自动消失，使用 `.transition(.move(edge: .bottom).combined(with: .opacity))` 动画。

**理由**：Chrome 风格的 toast 是用户已熟悉的交互模式，底部中央位置不遮挡主要内容，动画提供清晰的出现/消失反馈。

## Risks / Trade-offs

- **[CMD+W 与终端快捷键冲突]** → 终端标签页内可能使用 CMD+W 作为终端内快捷键（某些 shell 配置）。缓解：`.onKeyPress` 注册在页签栏容器而非终端内容区，终端内容区焦点时不触发页签关闭，符合规格。
- **[CMD+Q 2 秒窗口过短/过长]** → 2 秒超时是初始值，可能需要根据用户反馈调整。缓解：将超时值提取为常量，便于后续调整。
- **[`.onKeyPress` 最低版本]** → `.onKeyPress` 要求 macOS 14+，与项目最低部署目标一致，无额外风险。
- **[退出时资源释放]** → 单纯的 `terminate` 不证明资源释放。缓解：停机协调器在 terminate 前显式停止新任务、取消在途任务并关闭每个连接所有者；以 fake/mock 验证调用顺序与重复触发幂等性。
- **[远端操作中断结果不明]** → 关闭连接不等于远端未执行。缓解：停机过程不重放输入、命令或传输；无法确认的远端结果按既有错误/任务语义保留为未知或已取消，不伪报成功。
