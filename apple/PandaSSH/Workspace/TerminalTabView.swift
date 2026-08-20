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
        .onAppear { evaluateGate() }
        .onDisappear { session.close() }
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

    init(onReadError: @escaping () -> Void) {
        self.onReadError = onReadError
    }

    func setup(terminalView: TerminalView, connection: ShellConnection?) {
        self.terminalView = terminalView
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

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        try? connection?.resize(cols: UInt64(newCols), rows: UInt64(newRows))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

// MARK: - macOS

#if os(macOS)
private struct MacTerminalRepresentable: NSViewRepresentable {
    let connection: ShellConnection?
    let onReadError: () -> Void

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(onReadError: onReadError)
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero, font: nil)
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
        let tv = TerminalView(frame: .zero, font: nil)
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
