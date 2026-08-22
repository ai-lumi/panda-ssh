import SwiftUI
import SwiftTerm

/// 终端标签页：使用 SwiftTerm TerminalView 提供真终端体验
/// （ANSI 色彩、光标、滚动、选中文本、复制粘贴）。
/// 打开时先过连接门控（TOFU/密钥变更/密码），再进入约 800ms 的连接动画。
struct TerminalTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore

    let tab: WorkspaceTab
    let host: HostEntry

    @StateObject private var gate = PreconnectGate()
    @StateObject private var session: TerminalSessionStore

    init(tab: WorkspaceTab, host: HostEntry) {
        self.tab = tab
        self.host = host
        _session = StateObject(wrappedValue: TerminalSessionStore(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .background(Color.black)
        .onAppear {
            // 注册终端会话,供 WorkspaceStore 判断关闭确认门控与重连转发。
            workspace.registerTerminal(session, for: tab.id)
            evaluateGate()
        }
        .onDisappear {
            // 不在此注销会话:连接态由 connectedTerminalTabs 独立追踪,
            // 切换标签时视图销毁不应清除「已连接」标记(关闭确认仍需生效)。
            // 注销在 WorkspaceStore.close(tabID:) 中统一执行。
            session.close()
        }
        .onChange(of: session.phase) { _, newPhase in
            // 仅在进入 shell 时标记已连接;不在 .failed 时取消标记,
            // 因为 session.close()(切标签时)也会设 .failed,无法与真正断开区分。
            if newPhase == .shell {
                workspace.markTerminalConnected(tabID: tab.id)
            }
        }
        .preconnectSheets(gate: gate, host: host, tabID: tab.id)
        // 连接动画/mock 落结果；真实连接在门控通过后立即启动。
        .task(id: "\(session.attempt)-\(gate.unlocked)") {
            guard gate.unlocked, session.phase == .connecting else { return }
            if model.usesMockBackend {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                session.finishConnecting()
            } else {
                startRealConnection()
            }
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        Text("\(host.name) — \(host.username)@\(host.address):\(host.port) · \(statusText)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
    }

    private var statusText: String {
        switch session.phase {
        case .connecting: "连接中…"
        case .failed: "连接失败"
        case .shell: "已连接"
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if !gate.unlocked {
            // 门控对话框展示期间内容留空（取消即关标签）。
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch session.phase {
            case .connecting:
                connectingBody
            case .failed:
                ConnectFailureView(
                    host: host,
                    onRetry: { session.retry() },
                    onClose: { workspace.close(tabID: tab.id) }
                )
                .padding(24)
            case .shell:
                SwiftTermWrapper(
                    connection: session.connection,
                    onReadError: { session.markFailed() }
                )
            }
        }
    }

    /// 连接动画：进度指示器 + 「正在连接」文案。
    private var connectingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在连接 \(host.address):\(host.port) …")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - 行为

    private func evaluateGate() {
        if model.usesMockBackend {
            gate.evaluate(host: host)
        } else {
            Task {
                await gate.evaluateAsync(host: host, in: model) {
                    workspace.close(tabID: tab.id)
                }
            }
        }
    }

    private func startRealConnection() {
        guard let record = model.configRecord(for: host.id) else {
            session.markFailed()
            return
        }
        let secrets = CredentialResolver(keychain: SystemKeychain.shared)
            .connectionSecrets(for: host, manualPassword: gate.password)
        session.connect(
            record: record,
            password: secrets?.password,
            passphrase: secrets?.passphrase
        )
    }
}

// MARK: - SwiftTerm TerminalView SwiftUI 包装

/// SwiftTerm TerminalView 的跨平台 SwiftUI 包装。
/// 通过 NSViewRepresentable / UIViewRepresentable 将 SwiftTerm 的 TerminalView 桥接到 SwiftUI。
/// Coordinator 实现 TerminalViewDelegate，将用户输入转发到 ShellConnection，
/// 并通过读循环将远端输出馈送到 TerminalView。
struct SwiftTermWrapper: View {
    let connection: ShellConnection?
    let onReadError: () -> Void

    var body: some View {
        #if os(macOS)
        MacTerminalRepresentable(connection: connection, onReadError: onReadError)
        #elseif os(iOS)
        IOSTerminalRepresentable(connection: connection, onReadError: onReadError)
        #endif
    }
}

/// TerminalView 与 ShellConnection 之间的桥接器（macOS/iOS 共享）。
/// 实现 TerminalViewDelegate 将用户输入转发到 ShellConnection，
/// 并通过读循环将远端输出馈送到 TerminalView。
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    private weak var terminalView: TerminalView?
    private var connection: ShellConnection?
    private var readTask: Task<Void, Never>?
    private let onReadError: () -> Void

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

    init(onReadError: @escaping () -> Void) {
        self.onReadError = onReadError
    }

    func setup(terminalView: TerminalView, connection: ShellConnection?) {
        self.terminalView = terminalView
        // 强类型识别自定义终端视图子类，接线子类暴露的回调属性（不引入业务分支）：
        // - macOS `PandaTerminalView`：pandaDelegate（中键粘贴 / mouseUp PRIMARY 缓冲）、
        //   menuActionPerformer（右键菜单条目点击 → coordinator.perform）。
        // - iOS `PandaIOSTerminalView`：menuActionPerformer（长按 / 外接鼠标右键菜单点击）。
        //   iPad 端无 pandaDelegate（中键粘贴不启用，见 design.md 已知边界）。
        // 若传入裸 TerminalView（如旧测试），as? 失败即跳过接线，保持兼容。
        #if os(macOS)
        if let panda = terminalView as? PandaTerminalView {
            panda.pandaDelegate = self
            panda.menuActionPerformer = self
        }
        #else
        if let panda = terminalView as? PandaIOSTerminalView {
            panda.menuActionPerformer = self
        }
        #endif
        if let connection {
            update(connection: connection)
        }
    }

    func update(connection: ShellConnection?) {
        guard let connection, connection !== self.connection else { return }
        self.connection = connection
        startReading()
    }

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
        readTask?.cancel()
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try connection.read(max: 4096)
                    if !data.isEmpty {
                        await MainActor.run {
                            guard let self = self, let tv = self.terminalView else { return }
                            tv.feed(byteArray: Array(data)[...])
                        }
                        // 有数据时立即继续读取，不 sleep，降低延迟。
                        continue
                    }
                } catch {
                    await MainActor.run { self?.onReadError() }
                    break
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        try? connection?.write(Data(data))
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
            lastReportedTerminalSize = (newCols, newRows)
            Logger.shared.debug("终端初始尺寸上报 cols=\(newCols) rows=\(newRows)", module: LogModule.ssh)
            try? connection?.resize(cols: UInt64(newCols), rows: UInt64(newRows))
            return
        }
        lastReportedTerminalSize = (newCols, newRows)
        pendingResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let size = self.lastReportedTerminalSize else { return }
            Logger.shared.debug("终端尺寸去抖上报 cols=\(size.cols) rows=\(size.rows)", module: LogModule.ssh)
            try? self.connection?.resize(cols: UInt64(size.cols), rows: UInt64(size.rows))
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

// MARK: - TerminalMenuActionPerformer

extension TerminalCoordinator: TerminalMenuActionPerformer {
    func perform(_ item: TerminalMenuItem, hitLink: String?) {
        switch item {
        case .copyLink:
            guard let link = hitLink, !link.isEmpty else { return }
            #if os(macOS)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(link, forType: .string)
            #endif
        case .openLink:
            guard let link = hitLink, !link.isEmpty else { return }
            #if os(macOS)
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            #endif
        case .copy:
            #if os(macOS)
            terminalView?.copy(self)
            #endif
        case .paste:
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            try? connection?.write(text.data(using: .utf8) ?? Data())
        case .pasteAndEnter:
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            var data = text.data(using: .utf8) ?? Data()
            data.append(0x0A) // LF
            try? connection?.write(data)
        case .selectAll:
            terminalView?.selectAll()
            testDidCallSelectAll = true
        case .clearScreen:
            guard currentPhase == .shell, connection != nil else { return }
            try? connection?.write("clear\n".data(using: .utf8) ?? Data())
        case .resetTerminal:
            // macOS 端 SwiftTerm 公开了 `terminal` 属性，可直接 softReset；
            // iOS 端 `terminal` 为 internal，通过发送 RIS 序列让远端触发终端重置。
            #if os(macOS)
            terminalView?.terminal?.softReset()
            #endif
            try? connection?.write("\u{1B}c".data(using: .utf8) ?? Data())
        case .copyAndPaste:
            #if os(macOS)
            terminalView?.copy(self)
            #endif
            guard currentPhase == .shell else { return }
            let text = readClipboardText()
            guard !text.isEmpty else { return }
            try? connection?.write(text.data(using: .utf8) ?? Data())
        case .reconnect:
            onReconnect?()
        case .closeTab:
            onCloseTab?()
        }
    }

    /// 读取系统剪贴板文本（macOS 用 `NSPasteboard.general`，iOS 用 `UIPasteboard.general`）。
    private func readClipboardText() -> String {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return UIPasteboard.general.string ?? ""
        #endif
    }
}

#if os(macOS)
// MARK: - PandaTerminalViewDelegate + PRIMARY selection 缓冲（macOS only）

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
        guard currentPhase == .shell,
              !primarySelection.isEmpty,
              let connection = connection else { return }
        try? connection.write(primarySelection.data(using: .utf8) ?? Data())
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
        let original = pb.string(forType: .string)
        tv.copy(self)
        let selected = pb.string(forType: .string)
        // 恢复剪贴板：清除 copy 写入的内容，还回原值。
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
        let original = pb.string
        tv.copy(self)
        let selected = pb.string
        // 恢复剪贴板原值。
        pb.string = original
        guard let selected, !selected.isEmpty else { return nil }
        return selected
    }
}
#endif

// MARK: - macOS

#if os(macOS)
private struct MacTerminalRepresentable: NSViewRepresentable {
    let connection: ShellConnection?
    let onReadError: () -> Void

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(onReadError: onReadError)
    }

    func makeNSView(context: Context) -> TerminalView {
        // 使用 PandaTerminalView 子类：叠加中键粘贴、右键菜单、mouseUp PRIMARY 缓冲联动。
        // 子类识别与 pandaDelegate / menuActionPerformer 的接线在 `TerminalCoordinator.setup` 内完成，
        // 这里仅负责实例化与既有 SwiftTerm 配置（terminalDelegate / configureNativeColors）。
        let tv = PandaTerminalView(frame: .zero, font: nil)
        tv.terminalDelegate = context.coordinator
        tv.configureNativeColors()
        context.coordinator.setup(terminalView: tv, connection: connection)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.update(connection: connection)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.detach()
    }
}
#endif

// MARK: - iOS

#if os(iOS)
private struct IOSTerminalRepresentable: UIViewRepresentable {
    let connection: ShellConnection?
    let onReadError: () -> Void

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(onReadError: onReadError)
    }

    func makeUIView(context: Context) -> TerminalView {
        // 使用 PandaIOSTerminalView 子类：叠加「触摸长按 + 外接鼠标右键」触发的右键菜单。
        // menuActionPerformer 的接线在 `TerminalCoordinator.setup` 内完成。
        // 注：iPad 端不启用中键粘贴（SwiftTerm iOS 不区分鼠标按键，见 design.md 已知边界）。
        let tv = PandaIOSTerminalView(frame: .zero, font: nil)
        tv.terminalDelegate = context.coordinator
        context.coordinator.setup(terminalView: tv, connection: connection)
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.update(connection: connection)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.detach()
    }
}
#endif

#if DEBUG
#Preview("终端(shell)") {
    TerminalTabView(
        tab: WorkspaceTab(id: UUID(), hostID: "h-webprod", kind: .terminal, title: "web-prod"),
        host: MockBackend.demo().allHosts().first { $0.id == "h-webprod" }!
    )
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
}

#Preview("终端(连接超时)") {
    TerminalTabView(
        tab: WorkspaceTab(id: UUID(), hostID: "h-offline", kind: .terminal, title: "offline-srv"),
        host: MockBackend.demo().allHosts().first { $0.demo == .offline }!
    )
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
}
#endif
