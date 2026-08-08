import SwiftUI

/// SFTP 标签页:本地/远程双栏文件浏览器 + 右侧可开合的传输任务面板。
/// 打开时先过连接门控(与终端一致),再经约 800ms 连接动画进入双栏;
/// 连接失败展示重试/关闭,与原型 errbox 一致。
struct SftpTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var transfers: TransferStore
    @EnvironmentObject private var toast: ToastCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let tab: WorkspaceTab
    let host: HostEntry

    @StateObject private var gate = PreconnectGate()
    @StateObject private var session: SftpSessionStore

    /// 连接阶段:connecting →(约 800ms)→ connected / failed。
    private enum Phase {
        case connecting
        case connected
        case failed
    }

    @State private var phase: Phase = .connecting
    /// 连接尝试序号:重试时 +1,驱动 .task 重跑连接动画。
    @State private var attempt = 0
    @State private var panelOpen = false

    init(tab: WorkspaceTab, host: HostEntry, transfers: TransferStore) {
        self.tab = tab
        self.host = host
        // 会话与面板共享同一个全局 TransferStore(与原型全局传输列表一致)
        _session = StateObject(wrappedValue: SftpSessionStore(host: host, transfers: transfers))
    }

    var body: some View {
        Group {
            if !gate.unlocked {
                // 门控对话框展示期间内容留空(取消即关标签)
                Color.clear
            } else {
                switch phase {
                case .connecting:
                    ConnectingRow(host: host)
                case .failed:
                    ConnectFailureView(
                        host: host,
                        onRetry: {
                            attempt += 1
                            phase = .connecting
                        },
                        onClose: { workspace.close(tabID: tab.id) }
                    )
                    .padding(24)
                case .connected:
                    browser
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.usesMockBackend {
                session.useDemoSource()
            }
            evaluateGate()
        }
        .preconnectSheets(gate: gate, host: host, tabID: tab.id)
        .task(id: "\(attempt)-\(gate.unlocked)") {
            guard gate.unlocked, phase == .connecting else { return }
            if model.usesMockBackend {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                phase = host.demo == .offline ? .failed : .connected
            } else {
                await startRealConnection()
            }
        }
    }

    // MARK: - 双栏浏览器

    private var browser: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                pane(local: true)
                Divider()
                pane(local: false)
                // 常规宽度下面板内联在右侧;紧凑宽度(iPad 分屏/竖屏)改为右侧覆盖
                if panelOpen && horizontalSizeClass != .compact {
                    Divider()
                    TransferPanelView(store: transfers)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if panelOpen && horizontalSizeClass == .compact {
                TransferPanelView(store: transfers)
                    .shadow(radius: 12)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("SFTP · \(host.username)@\(host.address)", systemImage: "folder")
                .font(.callout.bold())
            Spacer()
            Button {
                panelOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("传输")
                    if transfers.activeCount > 0 {
                        Text("\(transfers.activeCount)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 单栏(本地 / 远程)

    private func pane(local: Bool) -> some View {
        let nav = local ? session.localPane : session.remotePane
        let selection = local ? session.selectedLocal : session.selectedRemote
        return VStack(spacing: 0) {
            paneHead(nav: nav, local: local)
            Divider()
            fileList(nav: nav, local: local)
            Divider()
            paneFoot(local: local, selection: selection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 栏头:标题 + 返回上级 + 面包屑。
    private func paneHead(nav: FilePaneNavigator, local: Bool) -> some View {
        HStack(spacing: 6) {
            Text(local ? "本地" : "远程 — \(host.name)")
                .font(.caption.bold())
            Button {
                Task {
                    local ? await session.goUpLocal() : await session.goUpRemote()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(nav.canGoUp ? Color.primary : Color.secondary.opacity(0.4))
            .disabled(!nav.canGoUp)
            .accessibilityLabel("返回上级")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // 栏头左侧已经显示「本地」或「远程 — host.name」，
                    // 面包屑跳过 rootTitle，避免重复显示。
                    ForEach(Array(nav.breadcrumbs.dropFirst().enumerated()), id: \.element.path) { index, crumb in
                        if index > 0 {
                            Text("›")
                                .foregroundStyle(.secondary)
                        }
                        Button(crumb.title) {
                            Task {
                                local ? await session.navigateLocal(to: crumb.path) : await session.navigateRemote(to: crumb.path)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// 文件列表:原生 List 负责单击选中与高亮;对已选中的目录再点一次即进入
    /// (单击选中、再点进入,双端一致,无需双击手势)。
    private func fileList(nav: FilePaneNavigator, local: Bool) -> some View {
        List(selection: selectionBinding(local: local)) {
            ForEach(nav.entries) { entry in
                fileRow(entry: entry)
                    .tag(entry.name)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 22)
        .overlay {
            if nav.entries.isEmpty {
                Text("空目录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 选中绑定:单击选中;再次点击已选中的目录则进入该目录。
    private func selectionBinding(local: Bool) -> Binding<String?> {
        Binding(
            get: { local ? session.selectedLocal : session.selectedRemote },
            set: { name in
                guard let name else { return }
                let nav = local ? session.localPane : session.remotePane
                let current = local ? session.selectedLocal : session.selectedRemote
                let isDirectory = nav.entries.first(where: { $0.name == name })?.isDirectory ?? false
                Task {
                    if name == current, isDirectory {
                        local ? await session.enterLocal(name) : await session.enterRemote(name)
                    } else {
                        local ? session.selectLocal(name) : session.selectRemote(name)
                    }
                }
            }
        )
    }

    /// 文件行:图标 + 名称 + 大小 + 修改时间(紧凑宽度隐藏);选中高亮由 List 负责。
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

    private func fileRow(entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? TerminalPalette.blue : Color.secondary)
                .frame(width: 20)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(entry.isDirectory ? "—" : formatBytes(entry.size))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if horizontalSizeClass != .compact {
                Text(entry.modified)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
        }
        .font(.system(size: 12.5))
    }

    /// 栏底:选中文件时出现「上传 →」/「← 下载」,否则显示操作提示。
    private func paneFoot(local: Bool, selection: String?) -> some View {
        HStack(spacing: 8) {
            if let selection {
                Text("已选：")
                    .foregroundStyle(.secondary)
                + Text(selection)
                    .bold()
                Spacer()
                Button(local ? "上传 →" : "← 下载") {
                    let task = local ? session.uploadSelected() : session.downloadSelected()
                    if let task {
                        toast.show((local ? "已加入上传队列：" : "已加入下载队列：") + task.name)
                        panelOpen = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(local ? "双击文件夹进入 · 选中文件后可上传" : "双击文件夹进入 · 选中文件后可下载")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
    }

    // MARK: - 真实连接

    private func startRealConnection() async {
        guard let record = model.configRecord(for: host.id) else {
            phase = .failed
            return
        }
        let secrets = CredentialResolver(keychain: SystemKeychain.shared)
            .connectionSecrets(for: host, manualPassword: gate.password)
        guard let secrets else {
            phase = .failed
            return
        }
        await session.connect(password: secrets.password, passphrase: secrets.passphrase)
        let localOK = await session.localPane.reload()
        let remoteOK = await session.remotePane.reload()
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        phase = (localOK && remoteOK) ? .connected : .failed
    }
}

#if DEBUG
#Preview("SFTP 双栏") {
    let transfers = TransferStore()
    return SftpTabView(
        tab: WorkspaceTab(id: UUID(), hostID: "h-webprod", kind: .sftp, title: "web-prod"),
        host: MockBackend.demo().allHosts().first { $0.id == "h-webprod" }!,
        transfers: transfers
    )
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
    .environmentObject(transfers)
}
#endif
