// =============================================================================
// TerminalTabView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了 SSH 终端标签页 (TerminalTabView)，是工作区中展示 SSH 终端会话的核心视图。
// 主要功能：
//   1. 连接门控：打开时先检查主机密钥信任 (TOFU)、密钥变更告警、密码/口令输入。
//   2. 连接动画：门控通过后显示约 800ms 的连接动画（Mock 模式下）或直接连接。
//   3. 终端渲染：使用 SwiftTerm 的 TerminalView 提供真终端体验（ANSI 色彩、光标、
//      滚动、选中文本、复制粘贴）。
//   4. 跨平台桥接：通过 NSViewRepresentable / UIViewRepresentable 将 SwiftTerm
//      的 TerminalView 桥接到 SwiftUI。
//   5. TerminalCoordinator：作为 TerminalView 的代理 (delegate)，负责：
//      - 将用户键盘输入转发到 SSH 通道
//      - 通过轮询读取远端输出并馈送到 TerminalView
//      - 处理终端尺寸变化并上报服务端（带去抖）
//      - macOS 上的 PRIMARY selection 缓冲（中键粘贴）
//      - 右键菜单操作（复制、粘贴、全选、清屏、重置等）
//
// 主要类型：
//   - TerminalContentPhase / TerminalContentPresentation: 终端内容阶段与呈现状态。
//   - TerminalTabView: 终端标签页主视图。
//   - SwiftTermWrapper: 跨平台 SwiftUI 包装视图。
//   - TerminalFocusRequestPolicy: 终端焦点请求的纯值规则。
//   - TerminalCoordinator: TerminalView 的代理与桥接器（核心）。
//   - MacTerminalRepresentable / IOSTerminalRepresentable: 平台特定的 Representable。
// =============================================================================

import SwiftUI
// 导入 SwiftTerm 库：提供 TerminalView（真终端渲染组件）
import SwiftTerm

/// SSH 内容页的共享几何与交互所有权；不承载连接状态机。
/// 定义终端内容的四个阶段：连接中、shell 运行中、正常结束、失败
enum TerminalContentPhase: Equatable { case connecting, shell, ended, failed }

/// 终端内容呈现参数：根据阶段和画布尺寸决定如何展示内容
struct TerminalContentPresentation: Equatable {
    /// overlay 类型：none = 无 overlay（shell 模式），centered = 居中 overlay（连接/结束/失败）
    enum Overlay: Equatable { case none, centered }
    /// 是否填满整个画布
    let fillsCanvas: Bool
    /// overlay 类型
    let overlay: Overlay
    /// 是否请求终端调整尺寸（仅在 shell 阶段且画布有效时）
    let requestsTerminalResize: Bool
    /// 画布宽度
    let canvasWidth: Double
    /// 画布高度
    let canvasHeight: Double
    /// 面板宽度：取 420 和 (画布宽度 - 32) 中的较小值
    var panelWidth: Double { min(420, max(0, canvasWidth - 32)) }

    /// 根据阶段和画布尺寸计算呈现参数
    static func resolve(phase: TerminalContentPhase, width: Double, height: Double) -> Self {
        // 确保宽高为非负有限值
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        return Self(fillsCanvas: true, overlay: phase == .shell ? .none : .centered,
                    // 仅在 shell 阶段且画布有效时才请求终端尺寸调整
                    requestsTerminalResize: phase == .shell && w > 0 && h > 0,
                    canvasWidth: w, canvasHeight: h)
    }
}

/// 终端标签页：使用 SwiftTerm TerminalView 提供真终端体验
/// （ANSI 色彩、光标、滚动、选中文本、复制粘贴）。
/// 打开时先过连接门控（TOFU/密钥变更/密码），再进入约 800ms 的连接动画。
struct TerminalTabView: View {
    // ── 环境对象 ──
    /// AppModel: 应用全局状态模型
    @EnvironmentObject private var model: AppModel
    /// WorkspaceStore: 工作区数据仓库
    @EnvironmentObject private var workspace: WorkspaceStore

    // ── 外部传入参数 ──
    /// 当前页签对象（包含 ID、主机 ID、类型、标题等）
    let tab: WorkspaceTab
    /// 当前连接的主机配置
    let host: HostEntry
    /// 工作区将所有终端常驻在视图树中；仅活动终端可请求键盘焦点。
    let isActive: Bool

    // ── 本地状态对象 ──
    /// 连接门控状态管理器：管理 TOFU 确认、密码输入等前置条件
    @StateObject private var gate = PreconnectGate()
    /// 终端会话存储：管理 SSH 连接状态、阶段、故障信息等
    @StateObject private var session: TerminalSessionStore

    /// 自定义初始化器：初始化 StateObject 需要 _session 语法
    init(tab: WorkspaceTab, host: HostEntry, isActive: Bool) {
        self.tab = tab
        self.host = host
        self.isActive = isActive
        // _session 是 StateObject 的投影语法，手动创建 TerminalSessionStore
        _session = StateObject(wrappedValue: TerminalSessionStore(host: host))
    }

    /// 视图主体
    var body: some View {
        // GeometryReader 获取可用区域的尺寸，用于计算终端画布大小
        GeometryReader { geometry in
            // 根据当前阶段和画布尺寸计算呈现参数
            let presentation = TerminalContentPresentation.resolve(
                phase: contentPhase, width: geometry.size.width, height: geometry.size.height)
            // 渲染内容并限制在画布尺寸内
            content(presentation: presentation)
                // .frame 固定内容尺寸为画布大小
                .frame(width: presentation.canvasWidth, height: presentation.canvasHeight)
                // .clipped() 裁剪超出 frame 的内容（防止终端内容溢出）
                .clipped()
        }
        // .background(Color.black) 终端背景为纯黑色（标准终端配色）
        .background(Color.black)
        // .onAppear 视图首次出现时执行初始化
        .onAppear {
            // 注册终端会话,供 WorkspaceStore 判断关闭确认门控与重连转发。
            workspace.registerTerminal(session, for: tab.id)
            // 上报初始连接状态
            workspace.reportConnectionStatus(status(for: session.phase), forTabID: tab.id)
            // 评估连接门控（检查是否需要 TOFU 确认、密码输入等）
            evaluateGate()
        }
        .onDisappear {
            // 切换到日志/监控等页面不会改变标签所有权；仅标签真正移除时关闭。
            guard !workspace.tabs.contains(where: { $0.id == tab.id }) else { return }
            // 不在此注销会话:连接态由 connectedTerminalTabs 独立追踪,
            // 切换标签时视图销毁不应清除「已连接」标记(关闭确认仍需生效)。
            // 注销在 WorkspaceStore.close(tabID:) 中统一执行。
            session.close()
            workspace.reportConnectionStatus(.failed, forTabID: tab.id)
        }
        // .onChange 监听会话阶段变化，同步更新连接状态
        .onChange(of: session.phase) { _, newPhase in
            workspace.reportConnectionStatus(status(for: newPhase), forTabID: tab.id)
        }
        // .onChange 监听故障信息变化，处理 TOFU 确认和凭据输入
        .onChange(of: session.failure) { _, failure in
            if failure == .missingCredential {
                // 缺少凭据：要求用户输入密码/口令
                session.waitForCredentialInput()
                gate.requireCredentialInput()
            } else if let key = failure.presentedHostKey,
                      gate.requireTofuConfirmation(key) {
                // 首次连接未知主机：缓存密钥指纹，等待用户确认
                model.backend.cachePresentedKey(key, for: host.id)
                session.waitForHostKeyConfirmation()
            }
        }
        // .preconnectSheets 挂载连接门控相关的 sheet（TOFU 确认框、密码输入框等）
        .preconnectSheets(gate: gate, host: host, tabID: tab.id)
        // .task 连接任务：门控通过后启动连接
        // id 参数确保 attempt 或 gate.unlocked 变化时重新执行
        .task(id: "\(session.attempt)-\(gate.unlocked)") {
            // 仅在门控已解锁且处于连接中阶段时执行
            guard gate.unlocked, session.phase == .connecting else { return }
            if model.usesMockBackend {
                // Mock 后端：等待 800ms 模拟连接延迟
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                // 模拟连接成功
                session.finishConnecting()
            } else {
                // 真实后端：启动 SSH 连接
                startRealConnection()
            }
        }
    }

    // MARK: - 内容区

    /// 根据门控状态和会话阶段渲染不同的内容视图
    @ViewBuilder
    private func content(presentation: TerminalContentPresentation) -> some View {
        if !gate.unlocked {
            // 门控对话框展示期间内容留空（取消即关标签）。
            // Color.clear 占满整个区域，确保布局稳定
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 门控已通过，根据会话阶段展示内容
            let readingAttempt = session.attempt
            // ZStack 叠加终端视图和状态 overlay
            ZStack(alignment: .bottom) {
                // SwiftTermWrapper: 真终端视图（ANSI 渲染、光标、滚动等）
                SwiftTermWrapper(
                    // SSH shell 连接
                    connection: session.connection,
                    // 当前会话阶段
                    phase: session.phase,
                    // 是否为活动终端（影响焦点）
                    isActive: isActive,
                    onReadError: { error in
                        // 读取错误回调：如果会话结束，通知 workspace
                        if session.handleSessionEnd(error, attempt: readingAttempt) {
                            workspace.handleTerminalSessionEnded(tabID: tab.id)
                        }
                    }
                )
                // 非 shell 阶段时显示状态 overlay（连接中/失败/结束）
                if session.phase != .shell {
                    terminalStatus
                }
            }
        }
    }

    /// 将会话阶段映射为内容阶段
    private var contentPhase: TerminalContentPhase {
        switch session.phase {
        // 连接中
        case .connecting: .connecting
        // shell 运行中
        case .shell: .shell
        // 正常结束
        case .ended: .ended
        // 连接失败
        case .failed: .failed
        }
    }

    /// 终端状态 overlay：在终端画布上方居中显示连接状态信息
    @ViewBuilder private var terminalStatus: some View {
        // VStack 垂直排列状态内容，间距 6pt
        VStack(spacing: 6) {
            switch session.phase {
            case .connecting:
                // 连接中：显示小型进度指示器 + 连接地址文字
                ProgressView().controlSize(.small)
                Text("正在连接 \(host.address):\(host.port) …")
            case .failed:
                // 连接失败：显示错误标题和详细信息
                Text(session.failure.title).font(.headline)
                Text(session.failure.detail)
            case .ended:
                // 会话正常结束：显示结束提示
                Text("SSH 会话已结束").font(.headline)
                Text("远端 shell 已正常退出。")
            case .shell:
                // shell 运行中不显示 overlay
                EmptyView()
            }
        }
        // .multilineTextAlignment(.center) 多行文字居中对齐
        .multilineTextAlignment(.center)
        // .font(.system(.caption, design: .monospaced)) 使用等宽字体 caption 字号
        .font(.system(.caption, design: .monospaced))
        // .padding(12) 内容四周留 12pt 内边距
        .padding(12)
        // .background 半透明黑色圆角背景（82% 不透明度），让状态文字在终端内容上可读
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // .padding(16) 背景外部再留 16pt 边距，让浮层不贴边
        .padding(16)
        // .allowsHitTesting(false) 状态 overlay 不拦截点击事件，让点击穿透到终端
        .allowsHitTesting(false)
    }

    /// 终端画布容器：黑色背景 + 居中 overlay 面板
    private func terminalCanvas<Overlay: View>(presentation: TerminalContentPresentation, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            // 底层：纯黑色背景
            Color.black
            // 上层：ScrollView 包裹 overlay 内容
            ScrollView {
                overlay()
                    // .frame(width:) 限制面板宽度
                    .frame(width: presentation.panelWidth)
                    // .padding(.vertical, 16) 面板上下留 16pt 边距
                    .padding(.vertical, 16)
                    // .frame(maxWidth: .infinity) 水平撑满
                    .frame(maxWidth: .infinity)
                    // .frame(minHeight:) 最小高度等于画布高度
                    .frame(minHeight: presentation.canvasHeight)
            }
        }
        // .frame(maxWidth: .infinity, maxHeight: .infinity) 撑满整个可用区域
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .environment(\.colorScheme, .dark) 强制深色模式（终端始终是深色背景）
        .environment(\.colorScheme, .dark)
    }

    /// 连接阶段 body 的居中 overlay 内容（进度指示器 + 连接地址文字）
    private var connectingBody: some View {
        VStack(spacing: 12) {
            // 小型进度指示器
            ProgressView()
                .controlSize(.small)
            // 连接地址文字
            Text("正在连接 \(host.address):\(host.port) …")
                // .foregroundStyle(.secondary) 使用二级灰色
                .foregroundStyle(.secondary)
        }
        // .frame(maxWidth: .infinity, alignment: .leading) 水平撑满，内容左对齐
        .frame(maxWidth: .infinity, alignment: .leading)
        // .padding(.horizontal, 12) 左右留 12pt 内边距
        .padding(.horizontal, 12)
        // .font(.system(.caption, design: .monospaced)) 等宽字体 caption 字号
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - 行为

    /// 评估连接门控：检查是否需要 TOFU 确认、密码输入等前置条件
    private func evaluateGate() {
        if model.usesMockBackend {
            // Mock 后端：同步评估（直接通过）
            gate.evaluate(host: host)
        } else {
            // 真实后端：异步评估（需要查询后端检查主机密钥等）
            Task {
                await gate.evaluateAsync(host: host, in: model) {
                    // 门控被取消时的回调：关闭此标签页
                    workspace.close(tabID: tab.id)
                }
            }
        }
    }

    /// 启动真实 SSH 连接
    private func startRealConnection() {
        // 获取主机配置记录（TOML 文件中的配置）
        guard let record = model.configRecord(for: host.id) else {
            // 配置不存在：标记连接失败
            session.markFailed()
            return
        }
        // 检查是否需要请求凭据输入（密码/口令）
        if gate.requestCredentialsIfNeeded(for: host) { return }
        // 解析连接凭据（从凭据文件或手动输入中获取密码/口令）
        let secrets = CredentialResolver()
            .connectionSecrets(for: host, manualSecret: gate.manualSecret)
        guard let secrets else {
            // 凭据不足：再次请求用户输入
            _ = gate.requestCredentialsIfNeeded(for: host)
            return
        }
        // 使用解析到的凭据启动 SSH 连接
        session.connect(
            record: record,
            // 密码（可为 nil）
            password: secrets.password,
            // 私钥口令（可为 nil）
            passphrase: secrets.passphrase
        )
    }

    /// 将会话阶段映射为工作区连接状态
    private func status(for phase: TerminalSessionStore.Phase) -> WorkspaceConnectionStatus {
        switch phase {
        // 连接中
        case .connecting: return .connecting
        // 已连接
        case .shell: return .connected
        // 未激活
        case .ended: return .inactive
        // 失败
        case .failed: return .failed
        }
    }
}

// MARK: - SwiftTerm TerminalView SwiftUI 包装

/// SwiftTerm TerminalView 的跨平台 SwiftUI 包装。
/// 通过 NSViewRepresentable / UIViewRepresentable 将 SwiftTerm 的 TerminalView 桥接到 SwiftUI。
/// Coordinator 实现 TerminalViewDelegate，将用户输入转发到 ShellConnection，
/// 并通过读循环将远端输出馈送到 TerminalView。
struct SwiftTermWrapper: View {
    /// SSH shell 连接（nil 表示尚未连接）
    let connection: ShellConnection?
    /// 当前会话阶段
    let phase: TerminalSessionStore.Phase
    /// 是否为活动终端（影响键盘焦点）
    let isActive: Bool
    /// 读取错误回调
    let onReadError: (Error) -> Void

    var body: some View {
        #if os(macOS)
        // macOS: 使用 NSViewRepresentable 桥接 TerminalView
        MacTerminalRepresentable(connection: connection, phase: phase, isActive: isActive, onReadError: onReadError)
        #elseif os(iOS)
        // iOS/iPadOS: 使用 UIViewRepresentable 桥接 TerminalView
        IOSTerminalRepresentable(connection: connection, phase: phase, isActive: isActive, onReadError: onReadError)
        #endif
    }
}

/// 终端是否应向原生系统请求键盘焦点的纯值规则。
/// 非活动终端为保活而留在视图树中，但绝不能抢占用户当前输入目标。
struct TerminalFocusRequestPolicy {
    /// 判断是否应该请求焦点：仅当终端刚变为可见（之前不可见）时才请求
    static func shouldRequestFocus(isVisible: Bool, wasVisible: Bool) -> Bool {
        // 现在可见 且 之前不可见 → 需要请求焦点
        isVisible && !wasVisible
    }
}

/// TerminalView 与 ShellConnection 之间的桥接器（macOS/iOS 共享）。
/// 实现 TerminalViewDelegate 将用户输入转发到 ShellConnection，
/// 并通过读循环将远端输出馈送到 TerminalView。
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    /// 弱引用 TerminalView（避免循环引用）
    private weak var terminalView: TerminalView?
    /// 当前 SSH shell 连接
    private var connection: ShellConnection?
    /// 轮询读取任务（后台 Task，16ms 间隔读取远端输出）
    private var readTask: Task<Void, Never>?
    /// 读取错误回调
    private let onReadError: (Error) -> Void
    /// 是否应该请求输入焦点
    private var shouldRequestInputFocus = false

    /// 最近一次上报（或待上报）给服务端的终端尺寸；nil 表示从未上报。
    /// 用于 `sizeChanged` 的「首次立即、连续去抖」策略。
    private var lastReportedTerminalSize: (cols: Int, rows: Int)?
    /// 去抖中的延迟上报任务；新的尺寸变化会取消前一个任务。
    private var pendingResizeWorkItem: DispatchWorkItem?

    #if os(macOS)
    /// 终端 PRIMARY selection 内部缓冲（macOS only，spec「终端选中即缓存 PRIMARY selection」）。
    /// mouseUp 后由 `PandaTerminalView` 调 `updatePrimarySelection(from:)` 更新；
    /// 中键点击时由 `pastePrimarySelection()` 写回 shell 通道。不污染系统剪贴板。
    private var primarySelection: String = ""
    #endif

    /// 当前终端会话阶段；测试可注入，生产代码由 `TerminalSessionStore` 同步。
    /// `pastePrimarySelection()` / 菜单可用性规则据此判断是否允许写入。
    internal var currentPhase: TerminalSessionStore.Phase = .shell

    /// 「重连」菜单项回调；由 `TerminalTabView` 在 §8 集成接入时注入 `session.retry()`。
    /// 测试中可注入 spy 闭包验证调用。
    var onReconnect: (() -> Void)?

    /// 「关闭标签页」菜单项回调；由 `TerminalTabView` 在 §8 集成接入时注入
    /// `workspace.close(tabID:)`（复用既有二次确认门控）。
    /// 测试中可注入 spy 闭包验证调用。
    var onCloseTab: (() -> Void)?

    // MARK: - 测试可见的统计（生产代码不读）

    /// 测试 hook：`selectAll()` 是否被调用。`TerminalView.selectAll` 是 `public`
    /// 非 `open` 方法，无法在 spy 子类中重写；用此 flag 验证调用。
    internal private(set) var testDidCallSelectAll = false

    /// 主初始化器：接收会话结束错误回调
    init(onSessionEnd: @escaping (Error) -> Void) {
        self.onReadError = onSessionEnd
    }

    /// 便捷初始化器：接收无参数回调（兼容旧测试）
    convenience init(onReadError: @escaping () -> Void) {
        self.init(onSessionEnd: { _ in onReadError() })
    }

    /// 上报错误：仅当错误来源是当前连接时才上报（避免旧连接的错误干扰）
    private func reportError(_ error: Error, from source: ShellConnection) {
        guard source === connection else { return }
        onReadError(error)
    }

    /// 设置终端视图和连接：初始化 coordinator 与 TerminalView 的关联
    func setup(terminalView: TerminalView, connection: ShellConnection?, phase: TerminalSessionStore.Phase) {
        self.terminalView = terminalView
        // 强类型识别自定义终端视图子类，接线子类暴露的回调属性（不引入业务分支）：
        // - macOS `PandaTerminalView`：pandaDelegate（中键粘贴 / mouseUp PRIMARY 缓冲）、
        //   menuActionPerformer（右键菜单条目点击 → coordinator.perform）。
        // - iOS `PandaIOSTerminalView`：menuActionPerformer（长按 / 外接鼠标右键菜单点击）。
        //   iPad 端无 pandaDelegate（中键粘贴不启用，见 design.md 已知边界）。
        // 若传入裸 TerminalView（如旧测试），as? 失败即跳过接线，保持兼容。
        #if os(macOS)
        if let panda = terminalView as? PandaTerminalView {
            // 设置 pandaDelegate 以接收中键粘贴和 PRIMARY selection 事件
            panda.pandaDelegate = self
            // 设置 menuActionPerformer 以接收右键菜单操作
            panda.menuActionPerformer = self
        }
        #else
        if let panda = terminalView as? PandaIOSTerminalView {
            // iOS: 只设置 menuActionPerformer（长按菜单）
            panda.menuActionPerformer = self
        }
        #endif
        // 更新连接和阶段
        update(connection: connection, phase: phase)
    }

    /// 兼容既有测试钩子；生产路径显式同步会话阶段。
    func setup(terminalView: TerminalView, connection: ShellConnection?) {
        setup(terminalView: terminalView, connection: connection, phase: currentPhase)
    }

    /// 更新连接和阶段：如果连接对象变化，重新启动读取循环
    func update(connection: ShellConnection?, phase: TerminalSessionStore.Phase) {
        // 同步当前阶段
        currentPhase = phase
        // 连接为 nil 时清空引用
        guard let connection else { self.connection = nil; return }
        // 连接对象未变化时跳过
        guard connection !== self.connection else { return }
        self.connection = connection
        // 终端布局可能早于异步 SSH 建连完成。旧连接或无连接期间留下的
        // 去抖任务不能作用于新连接；新 PTY 则必须立即获得当前已知尺寸。
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        if let size = lastReportedTerminalSize {
            Logger.shared.debug("终端连接就绪，补发初始尺寸 cols=\(size.cols) rows=\(size.rows)", module: LogModule.ssh)
            try? connection.resize(cols: UInt64(size.cols), rows: UInt64(size.rows))
        }
        // 新连接：启动读取循环
        startReading()
    }

    /// 兼容既有测试钩子；生产路径显式同步会话阶段。
    func update(connection: ShellConnection?) {
        update(connection: connection, phase: currentPhase)
    }

    /// 视图更新时同步活动资格，再异步请求焦点，确保终端已加入原生视图层级。
    func updateInputFocusEligibility(isVisible: Bool) -> Bool {
        // 根据焦点策略判断是否应该请求焦点
        let shouldRequest = TerminalFocusRequestPolicy.shouldRequestFocus(
            isVisible: isVisible,
            wasVisible: shouldRequestInputFocus
        )
        // 更新「之前是否可见」的状态
        shouldRequestInputFocus = isVisible
        return shouldRequest
    }

    #if os(macOS)
    /// macOS: 请求终端视图获取键盘焦点（使其成为 first responder）
    func requestInputFocus(for terminalView: TerminalView) {
        // 异步到主线程执行，确保视图已加入窗口
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self, self.shouldRequestInputFocus, let terminalView else { return }
            // makeFirstResponder 让终端视图成为键盘事件的第一接收者
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }
    #elseif os(iOS)
    /// iOS: 请求终端视图获取键盘焦点
    func requestInputFocus(for terminalView: TerminalView) {
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self, self.shouldRequestInputFocus, let terminalView else { return }
            // becomeFirstResponder 让终端视图成为键盘事件的第一接收者
            _ = terminalView.becomeFirstResponder()
        }
    }
    #endif

    /// 断开所有关联：取消读取任务、清空引用、解除 delegate 绑定
    func detach() {
        readTask?.cancel()
        readTask = nil
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        lastReportedTerminalSize = nil
        terminalView?.terminalDelegate = nil
        terminalView = nil
        connection = nil
    }

    /// 轮询读取远端输出并馈送到 TerminalView。
    /// 在后台 Task 中执行，16ms 间隔；有数据时跳过 sleep 立即再次读取，
    /// 无数据时短暂休眠以降低 CPU。数据通过 MainActor.run 提交到 UI。
    private func startReading() {
        guard let connection else { return }
        // 取消之前的读取任务（如果有）
        readTask?.cancel()
        // Coordinator 与读取任务在视图存续期内共同存活；dismantle 时 detach()
        // 会取消任务并打破引用环。使用稳定强引用也避免 Swift 6 将弱变量跨
        // MainActor 闭包捕获判定为并发不安全。
        readTask = Task { [self] in
            while !Task.isCancelled {
                do {
                    // 从 SSH 连接读取最多 4096 字节的数据
                    let data = try connection.read(max: 4096)
                    if !data.isEmpty {
                        // 有数据：切换到主线程更新 TerminalView
                        await MainActor.run {
                            // 再次检查任务是否已取消、连接是否仍然有效
                            guard !Task.isCancelled, self.connection === connection,
                                  let tv = self.terminalView else { return }
                            // 将字节数据馈送到 TerminalView 进行 ANSI 解析和渲染
                            tv.feed(byteArray: Array(data)[...])
                        }
                        // 有数据时立即继续读取，不 sleep，降低延迟。
                        continue
                    }
                } catch {
                    // 读取错误：如果任务未被取消，上报错误
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.reportError(error, from: connection) }
                    break
                }
                // 无数据时休眠 16ms（约 60fps），降低 CPU 占用
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: - TerminalViewDelegate

    /// TerminalViewDelegate: 用户在终端中输入数据时调用，转发到 shell
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendToShell(Data(data))
    }

    /// 所有终端输入统一走此入口；暂时背压只提示并保留会话，真正写入失败才结束读循环。
    internal func sendToShell(_ data: Data) {
        // 仅在 shell 阶段且有连接时才写入
        guard currentPhase == .shell, let connection else { return }
        do {
            // 尝试将数据写入 SSH 通道
            try connection.write(data)
        } catch {
            if let panda = error as? PandaError, case .ShellInputBackpressure = panda {
                // 输入背压（暂时拥塞）：仅警告，不结束会话
                Logger.shared.warning("SSH 输入暂时拥塞；本次输入未发送", module: LogModule.ssh)
                return
            }
            // 其他错误：上报错误（可能导致会话结束）
            reportError(error, from: connection)
        }
    }

    /// 视图尺寸变化回调（SwiftTerm 在**主线程布局过程**中同步触发）。
    ///
    /// 侧栏显隐、窗口拖拽等动画会让该回调以逐帧频率连续触发（一次动画约 20 次）。
    /// 若逐帧向服务端发送 `window-change`，远端 shell 会收到 SIGWINCH 风暴；
    /// 其重绘序列与本地逐帧 reflow 交错时，可能把光标推到屏幕中部
    /// （表现为终端上方出现大片空白、prompt「沉底」）。
    ///
    /// 策略：首次回调立即上报（连接建立后让服务端尽快拿到真实尺寸）；
    /// 后续连续变化做 150ms 去抖，只在尺寸稳定后上报最终值。
    /// 本地 SwiftTerm 的逐帧 reflow 不受影响（视图层行为不变）。
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if lastReportedTerminalSize == nil {
            // 首次尺寸变化：立即上报，让服务端尽快获取真实终端尺寸
            lastReportedTerminalSize = (newCols, newRows)
            Logger.shared.debug("终端初始尺寸上报 cols=\(newCols) rows=\(newRows)", module: LogModule.ssh)
            try? connection?.resize(cols: UInt64(newCols), rows: UInt64(newRows))
            return
        }
        // 后续尺寸变化：更新缓存值，启动 150ms 去抖
        lastReportedTerminalSize = (newCols, newRows)
        // 取消之前的去抖任务（如果有）
        pendingResizeWorkItem?.cancel()
        // 创建新的去抖任务：150ms 后上报最终尺寸
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let size = self.lastReportedTerminalSize else { return }
            Logger.shared.debug("终端尺寸去抖上报 cols=\(size.cols) rows=\(size.rows)", module: LogModule.ssh)
            try? self.connection?.resize(cols: UInt64(size.cols), rows: UInt64(size.rows))
        }
        pendingResizeWorkItem = workItem
        // 150ms 后执行去抖任务
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
    /// TerminalViewDelegate: 终端标题变化回调（当前为空实现）
    func setTerminalTitle(source: TerminalView, title: String) {}
    /// TerminalViewDelegate: 当前目录变化回调（当前为空实现）
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    /// TerminalViewDelegate: 滚动位置变化回调（当前为空实现）
    func scrolled(source: TerminalView, position: Double) {}
    /// TerminalViewDelegate: 可见行范围变化回调（当前为空实现）
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    /// TerminalViewDelegate: 请求打开链接回调（当前为空实现）
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

// MARK: - TerminalMenuActionPerformer

/// 终端菜单操作执行器：处理右键菜单/长按菜单中的各种操作
extension TerminalCoordinator: TerminalMenuActionPerformer {
    /// 执行菜单项操作
    func perform(_ item: TerminalMenuItem, hitLink: String?) {
        switch item {
        case .copyLink:
            // 复制链接：将链接文本写入系统剪贴板
            guard let link = hitLink, !link.isEmpty else { return }
            #if os(macOS)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(link, forType: .string)
            #endif
        case .openLink:
            // 打开链接：使用系统默认浏览器打开 URL
            guard let link = hitLink, !link.isEmpty else { return }
            #if os(macOS)
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            #endif
        case .copy:
            // 复制：调用 TerminalView 的 copy 方法复制选中文本到剪贴板
            #if os(macOS)
            terminalView?.copy(self)
            #endif
        case .paste:
            // 粘贴：从剪贴板读取文本并发送到 shell（不追加换行）
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            sendToShell(text.data(using: .utf8) ?? Data())
        case .pasteAndEnter:
            // 粘贴并回车：从剪贴板读取文本，追加 LF（换行符 0x0A）后发送到 shell
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            var data = text.data(using: .utf8) ?? Data()
            // LF（换行符）
            data.append(0x0A)
            sendToShell(data)
        case .selectAll:
            // 全选：选中终端中所有内容
            terminalView?.selectAll()
            testDidCallSelectAll = true
        case .clearScreen:
            // 清屏：发送 "clear\n" 命令到 shell
            guard currentPhase == .shell, connection != nil else { return }
            sendToShell("clear\n".data(using: .utf8) ?? Data())
        case .resetTerminal:
            // 重置终端：macOS 用 softReset，iOS 发送 RIS 序列 (\u{1B}c)
            // macOS 端 SwiftTerm 公开了 `terminal` 属性，可直接 softReset；
            // iOS 端 `terminal` 为 internal，通过发送 RIS 序列让远端触发终端重置。
            #if os(macOS)
            terminalView?.terminal?.softReset()
            #endif
            sendToShell("\u{1B}c".data(using: .utf8) ?? Data())
        case .copyAndPaste:
            // 复制并粘贴：先复制选中文本到剪贴板，再从剪贴板读取并发送到 shell
            #if os(macOS)
            terminalView?.copy(self)
            #endif
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            sendToShell(text.data(using: .utf8) ?? Data())
        case .reconnect:
            // 重连：触发外部注入的重连回调
            onReconnect?()
        case .closeTab:
            // 关闭标签：触发外部注入的关闭回调
            onCloseTab?()
        }
    }

    /// 读取系统剪贴板文本（macOS 用 `NSPasteboard.general`，iOS 用 `UIPasteboard.general`）。
    private func readClipboardText() -> String {
        #if os(macOS)
        // macOS: 从 NSPasteboard 读取字符串
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        // iOS: 从 UIPasteboard 读取字符串
        return UIPasteboard.general.string ?? ""
        #endif
    }
}

#if os(macOS)
// MARK: - PandaTerminalViewDelegate + PRIMARY selection 缓冲（macOS only）

/// macOS 专有：PRIMARY selection 缓冲与中键粘贴支持
extension TerminalCoordinator: PandaTerminalViewDelegate {

    /// 从终端视图选中文本更新 PRIMARY 缓冲。空字符串不覆盖既有非空缓冲。
    /// 由 `PandaTerminalView.mouseUp` 调用。
    func updatePrimarySelection(from tv: TerminalView) {
        let text = Self.readSelectedText(from: tv)
        updatePrimarySelection(from: text)
    }

    /// 测试可注入的重载：直接接受选中文本字符串，绕过 SwiftTerm `selection` 访问。
    /// - Note: 空字符串或 nil 不覆盖既有非空缓冲（spec「选中空字符串不覆盖」）。
    internal func updatePrimarySelection(from selectedText: String?) {
        guard let text = selectedText, !text.isEmpty else { return }
        primarySelection = text
    }

    /// 把 PRIMARY 缓冲写入当前 shell 通道（中键粘贴语义）。
    /// - 仅在 `.shell` 阶段写入；`.connecting` / `.failed` 阶段不写入。
    /// - 不追加换行符（spec「SHALL NOT 追加换行符」）。
    /// - 不修改系统剪贴板（spec「SHALL NOT 写入系统剪贴板」）。
    func pastePrimarySelection() {
        guard currentPhase == .shell, !primarySelection.isEmpty else { return }
        sendToShell(primarySelection.data(using: .utf8) ?? Data())
    }

    /// 测试可见的 PRIMARY 缓冲读取入口（便于断言缓冲值）。
    internal var primarySelectionForTesting: String {
        primarySelection
    }

    /// 从 SwiftTerm `TerminalView` 读取选中文本。
    ///
    /// SwiftTerm 的 `selection` 属性与其类型 `SelectionService` 均为 `internal`，
    /// 跨模块（PandaSSH → SwiftTerm）既不能命名 `SelectionService`，也无法经 KVC 取值
    /// （`selection` 非 `@objc`，`value(forKey: "selection")` 会抛 `NSUnknownKeyException`）。
    /// SwiftTerm 未暴露任何公共「选中文本」读取入口（仅 `selectionActive` / 颜色等公共）。
    ///
    /// 采用「瞬态复制 + 恢复剪贴板」模式：
    /// 1. 保存当前系统剪贴板字符串；
    /// 2. 调 `tv.copy(self)` 把 SwiftTerm 选中写入剪贴板；
    /// 3. 读取剪贴板得到选中文本；
    /// 4. 恢复剪贴板原值。
    /// 净效果：用户剪贴板内容不变，spec「SHALL NOT 写入系统剪贴板」语义满足（不永久修改）。
    ///
    /// - Parameter tv: 当前终端视图（必须是 SwiftTerm `TerminalView` 实例）。
    /// - Returns: 非空选中文本；无选中或读取失败时返回 nil。
    internal static func readSelectedText(from tv: TerminalView) -> String? {
        let pb = NSPasteboard.general
        // 1. 保存当前剪贴板内容
        let original = pb.string(forType: .string)
        // 2. 调用 TerminalView 的 copy 方法，将选中文本写入剪贴板
        tv.copy(self)
        // 3. 从剪贴板读取选中文本
        let selected = pb.string(forType: .string)
        // 4. 恢复剪贴板：清除 copy 写入的内容，还回原值。
        pb.clearContents()
        if let original {
            pb.setString(original, forType: .string)
        }
        guard let selected, !selected.isEmpty else { return nil }
        return selected
    }
}
#endif

#if os(iOS)
// MARK: - iOS 终端选中文本读取（瞬态 copy + 恢复剪贴板）

/// iOS 专有：从 SwiftTerm iOS TerminalView 读取选中文本
extension TerminalCoordinator {

    /// 从 SwiftTerm iOS `TerminalView` 读取选中文本。
    ///
    /// SwiftTerm iOS 的 `selection` 属性为 `internal`，跨模块不可访问；
    /// 但 `copy(_:)` 是 `@objc open`（公开），会把选中文本写入 `UIPasteboard.general`。
    /// 采用与 macOS 相同的「瞬态 copy + 恢复剪贴板」模式：
    /// 1. 保存当前 `UIPasteboard.general.string`；
    /// 2. 调 `tv.copy(self)` 把选中写入剪贴板；
    /// 3. 读取剪贴板得到选中文本；
    /// 4. 恢复剪贴板原值。
    /// 净效果：用户剪贴板内容不变（瞬态写入边界见 spec/design 已知边界）。
    ///
    /// - Parameter tv: 当前终端视图（必须是 SwiftTerm `TerminalView` 实例）。
    /// - Returns: 非空选中文本；无选中或读取失败时返回 nil。
    internal static func readSelectedText(from tv: TerminalView) -> String? {
        let pb = UIPasteboard.general
        // 1. 保存当前剪贴板内容
        let original = pb.string
        // 2. 调用 TerminalView 的 copy 方法，将选中文本写入剪贴板
        tv.copy(self)
        // 3. 从剪贴板读取选中文本
        let selected = pb.string
        // 4. 恢复剪贴板原值。
        pb.string = original
        guard let selected, !selected.isEmpty else { return nil }
        return selected
    }
}
#endif

// MARK: - macOS

#if os(macOS)
/// macOS 平台的 NSViewRepresentable：将 SwiftTerm TerminalView 桥接到 SwiftUI
private struct MacTerminalRepresentable: NSViewRepresentable {
    /// SSH shell 连接
    let connection: ShellConnection?
    /// 当前会话阶段
    let phase: TerminalSessionStore.Phase
    /// 是否为活动终端
    let isActive: Bool
    /// 读取错误回调
    let onReadError: (Error) -> Void

    /// 创建 Coordinator（代理/桥接器）
    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(onSessionEnd: onReadError)
    }

    /// 创建原生 TerminalView（首次创建时调用）
    func makeNSView(context: Context) -> TerminalView {
        // 使用 PandaTerminalView 子类：叠加中键粘贴、右键菜单、mouseUp PRIMARY 缓冲联动。
        // 子类识别与 pandaDelegate / menuActionPerformer 的接线在 `TerminalCoordinator.setup` 内完成，
        // 这里仅负责实例化与既有 SwiftTerm 配置（terminalDelegate / configureNativeColors）。
        let tv = PandaTerminalView(frame: .zero, font: nil)
        // 设置 terminalDelegate 为 coordinator，接收终端事件（输入、尺寸变化等）
        tv.terminalDelegate = context.coordinator
        // 配置原生颜色（背景色、前景色等，匹配系统外观）
        tv.configureNativeColors()
        // 更新呈现可见性（活动终端可见，非活动终端可能隐藏）
        tv.updatePresentationVisibility(isActive)
        // 设置 coordinator 与 TerminalView 的关联（连接、阶段等）
        context.coordinator.setup(terminalView: tv, connection: connection, phase: phase)
        // 检查是否应该请求键盘焦点
        if context.coordinator.updateInputFocusEligibility(isVisible: isActive) {
            context.coordinator.requestInputFocus(for: tv)
        }
        return tv
    }

    /// 更新原生 TerminalView（SwiftUI 重新渲染时调用）
    func updateNSView(_ nsView: TerminalView, context: Context) {
        // 更新呈现可见性
        (nsView as? PandaTerminalView)?.updatePresentationVisibility(isActive)
        // 更新连接和阶段
        context.coordinator.update(connection: connection, phase: phase)
        // 检查并请求焦点
        if context.coordinator.updateInputFocusEligibility(isVisible: isActive) {
            context.coordinator.requestInputFocus(for: nsView)
        }
    }

    /// 视图从 SwiftUI 树中移除时调用：断开 coordinator 的所有关联
    static func dismantleNSView(_ nsView: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.detach()
    }
}
#endif

// MARK: - iOS

#if os(iOS)
/// iOS/iPadOS 平台的 UIViewRepresentable：将 SwiftTerm TerminalView 桥接到 SwiftUI
private struct IOSTerminalRepresentable: UIViewRepresentable {
    /// SSH shell 连接
    let connection: ShellConnection?
    /// 当前会话阶段
    let phase: TerminalSessionStore.Phase
    /// 是否为活动终端
    let isActive: Bool
    /// 读取错误回调
    let onReadError: (Error) -> Void

    /// 创建 Coordinator（代理/桥接器）
    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(onSessionEnd: onReadError)
    }

    /// 创建原生 TerminalView（首次创建时调用）
    func makeUIView(context: Context) -> TerminalView {
        // 使用 PandaIOSTerminalView 子类：叠加「触摸长按 + 外接鼠标右键」触发的右键菜单。
        // menuActionPerformer 的接线在 `TerminalCoordinator.setup` 内完成。
        // 注：iPad 端不启用中键粘贴（SwiftTerm iOS 不区分鼠标按键，见 design.md 已知边界）。
        let tv = PandaIOSTerminalView(frame: .zero, font: nil)
        // 设置 terminalDelegate 为 coordinator
        tv.terminalDelegate = context.coordinator
        // 设置 coordinator 与 TerminalView 的关联
        context.coordinator.setup(terminalView: tv, connection: connection, phase: phase)
        // 检查并请求焦点
        if context.coordinator.updateInputFocusEligibility(isVisible: isActive) {
            context.coordinator.requestInputFocus(for: tv)
        }
        return tv
    }

    /// 更新原生 TerminalView（SwiftUI 重新渲染时调用）
    func updateUIView(_ uiView: TerminalView, context: Context) {
        // 更新连接和阶段
        context.coordinator.update(connection: connection, phase: phase)
        // 检查并请求焦点
        if context.coordinator.updateInputFocusEligibility(isVisible: isActive) {
            context.coordinator.requestInputFocus(for: uiView)
        }
    }

    /// 视图从 SwiftUI 树中移除时调用：断开 coordinator 的所有关联
    static func dismantleUIView(_ uiView: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.detach()
    }
}
#endif

#if DEBUG
/// Xcode Preview: 终端正常连接状态
#Preview("终端(shell)") {
    TerminalTabView(
        tab: WorkspaceTab(id: UUID(), hostID: "h-webprod", kind: .terminal, title: "web-prod"),
        host: MockBackend.demo().allHosts().first { $0.id == "h-webprod" }!,
        isActive: true
    )
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
}

/// Xcode Preview: 终端连接超时状态
#Preview("终端(连接超时)") {
    TerminalTabView(
        tab: WorkspaceTab(id: UUID(), hostID: "h-offline", kind: .terminal, title: "offline-srv"),
        host: MockBackend.demo().allHosts().first { $0.demo == .offline }!,
        isActive: true
    )
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
}
#endif
