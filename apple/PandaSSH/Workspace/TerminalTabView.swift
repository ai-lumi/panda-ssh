import SwiftUI

/// 终端标签页:深色终端外观 + 假 shell(本 milestone 只做 UI 验证,
/// 不引 SwiftTerm;真实 SSH 数据流接线留给后续 milestone)。
/// 打开时先过连接门控(TOFU/密钥变更/密码),再进入约 800ms 的连接动画。
struct TerminalTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore

    let tab: WorkspaceTab
    let host: HostEntry

    @StateObject private var gate = PreconnectGate()
    @StateObject private var session: TerminalSessionStore

    @State private var input = ""
    @State private var cursorVisible = true
    @FocusState private var inputFocused: Bool

    /// 闪烁光标节拍(原型为 1s 闪烁,这里 0.5s 翻转一次)。
    private let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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
        .background(TerminalPalette.background)
        .onAppear { evaluateGate() }
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
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(TerminalPalette.dim)
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
            // 门控对话框展示期间内容留空(取消即关标签,与原型「不打开标签」等价)
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
                shellBody
            }
        }
    }

    /// 连接动画:输出「正在连接 …」行 + 转圈。
    private var connectingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(session.lines) { line in
                    termText(line)
                }
                ProgressView()
                    .controlSize(.small)
                    .tint(TerminalPalette.green)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .font(TerminalPalette.font)
    }

    /// shell:输出区(自动滚到底) + 底部输入行(prompt + 输入框 + 闪烁光标)。
    private var shellBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.lines) { line in
                            termText(line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = true }
                .onChange(of: session.lines.count) { _, _ in
                    if let last = session.lines.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            inputRow
        }
        .font(TerminalPalette.font)
        .onAppear { inputFocused = true }
    }

    private var inputRow: some View {
        HStack(spacing: 0) {
            Text(session.prompt)
                .foregroundStyle(TerminalPalette.green)
            Text(" ")
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(TerminalPalette.font)
                .foregroundStyle(TerminalPalette.plain)
                .focused($inputFocused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) {
                    input = session.historyUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    input = session.historyDown()
                    return .handled
                }
            #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
            #endif
            // 闪烁块状光标:输入为空时显示(输入时系统光标已可见,避免双重光标)
            if input.isEmpty {
                Rectangle()
                    .fill(TerminalPalette.green)
                    .frame(width: 7, height: 14)
                    .opacity(cursorVisible ? 1 : 0)
                    .onReceive(blinkTimer) { _ in cursorVisible.toggle() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 行为

    private func submit() {
        let result = session.run(input)
        input = ""
        if result == .closeTab {
            workspace.close(tabID: tab.id)
        }
    }

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

    private func termText(_ line: TermLine) -> Text {
        line.segments.reduce(Text("")) { partial, segment in
            partial + Text(segment.text).foregroundStyle(TerminalPalette.color(for: segment.role))
        }
    }
}

/// 终端配色(对应原型 .term 系列 CSS)。
enum TerminalPalette {
    static let font = Font.system(size: 12.5, design: .monospaced)
    static let background = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x24 / 255)
    static let plain = Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xEA / 255)
    static let dim = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x96 / 255)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let red = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x63 / 255)
    static let yellow = Color(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255)
    static let blue = Color(red: 0x5A / 255, green: 0xC8 / 255, blue: 0xFA / 255)

    static func color(for role: TermSegment.Role) -> Color {
        switch role {
        case .plain: plain
        case .dim: dim
        case .green: green
        case .red: red
        case .yellow: yellow
        case .blue: blue
        }
    }
}

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
