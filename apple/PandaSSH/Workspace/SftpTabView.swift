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
    /// 待确认删除的条目;nil 表示未触发删除确认。
    @State private var deleteCandidate: (entry: FileEntry, local: Bool)? = nil

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
        .sheet(item: $session.pendingConflict) { conflict in
            OverwriteConfirmationSheet(conflict: conflict) { overwrite in
                session.resolveConflict(overwrite: overwrite)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.usesMockBackend {
                session.useDemoSource()
            }
            evaluateGate()
        }
        .onDisappear { session.disconnect() }
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
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    pane(local: true)
                    Divider()
                    pane(local: false)
                }
            }

            // 抽屉式传输面板：悬浮在主窗口上方，不挤占空间
            if panelOpen {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { panelOpen = false }
                    .transition(.opacity)

                HStack {
                    Spacer()
                    TransferPanelView(store: transfers)
                        .frame(width: 340)
                        .background(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 16, x: -4, y: 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: panelOpen)
            }
        }
        .alert("确认删除", isPresented: .init(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), actions: {
            Button("删除", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                Task {
                    let error = candidate.local
                        ? await session.deleteLocal(name: candidate.entry.name)
                        : await session.deleteRemote(name: candidate.entry.name)
                    if let error {
                        toast.show("删除 \(candidate.entry.name) 失败：\(error)")
                    } else {
                        toast.show("已删除 \(candidate.entry.name)")
                    }
                }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        }, message: {
            if let candidate = deleteCandidate {
                Text("确定要删除「\(candidate.entry.name)」吗？此操作不可撤销。")
            }
        })
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
                            .font(.caption2)
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
        return VStack(spacing: 0) {
            paneHead(nav: nav, local: local)
            Divider()
            fileList(nav: nav, local: local)
            Divider()
            paneFoot(local: local)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 栏头:标题(点击回根目录) + 返回上级 + 面包屑 + 右侧操作按钮。
    private func paneHead(nav: FilePaneNavigator, local: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    local ? await session.navigateLocal(to: nav.root) : await session.navigateRemote(to: nav.root)
                }
            } label: {
                Text(local ? "本地" : "远程 — \(host.name)")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回顶级目录")
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
            Button {
                Task {
                    local ? await session.localPane.reload() : await session.remotePane.reload()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新当前目录")

            paneHeadActions(local: local)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func paneHeadActions(local: Bool) -> some View {
        if local {
            Button {
                session.toggleLocalMultiSelect()
            } label: {
                Text(session.isLocalMultiSelect ? "完成" : "选择")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isLocalMultiSelect ? "完成选择" : "进入本地多选模式")
            Button {
                Task { await pickAndUploadLocalFiles() }
            } label: {
                Label("上传", systemImage: "arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择本地文件或目录上传")
        } else {
            Button {
                session.toggleRemoteMultiSelect()
            } label: {
                Text(session.isRemoteMultiSelect ? "完成" : "选择")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isRemoteMultiSelect ? "完成选择" : "进入多选模式")
        }
    }

    private func pickAndUploadLocalFiles() async {
        guard let picked = await SystemLocalFilePicker.shared.pickFiles() else { return }
        let tasks = session.upload(localPaths: picked.paths)
        if let first = tasks.first {
            toast.show("已加入批量上传队列：\(first.name) 等 \(tasks.count) 项")
            panelOpen = true
        }
    }

    /// 文件列表:手动管理选中状态,提供与 Finder / Files App 一致的交互。
    /// - 单击条目高亮/选中;未按修饰键时单选互斥,按 ⌘ 时追加/取消多选。
    /// - 双击目录进入子目录。
    /// - 多选模式显示复选框。
    /// - macOS 支持鼠标拖拽框选(用 simultaneousGesture,不阻塞行的点击)。
    ///
    /// 注意:此处使用 ScrollView + LazyVStack 而非 List,因为 SwiftUI List 的
    /// 内部 content inset 会导致 DragGesture 坐标与 GeometryReader 行 frame
    /// 不在同一原点,从而框选矩形与真实选中条目错位。
    ///
    /// 框选矩形必须放在 ScrollView 内部的 ZStack 中,而非 ScrollView 的 .overlay,
    /// 因为 .overlay 使用 ScrollView 的可见区域(clip)坐标系,而 DragGesture 与
    /// GeometryReader 使用的是 ScrollView 的内容(content)坐标系;两者在 macOS 上
    /// 存在原点偏移,导致矩形与真实选中条目错位。将矩形移入内部确保三者在同一
    /// 坐标空间。
    /// 只在拖拽态收集条目 frame，避免大目录下每行常驻 GeometryReader 的布局开销。
    @ViewBuilder
    private func rowFrameCollector(entry: FileEntry, local: Bool) -> some View {
        let dragActive = (local ? localDragRect : remoteDragRect) != nil
        if dragActive {
            GeometryReader { geo in
                Color.clear.preference(
                    key: FileRowFrameKey.self,
                    value: [entry.name: geo.frame(in: .named("filePaneSpace"))]
                )
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func fileList(nav: FilePaneNavigator, local: Bool) -> some View {
        let multiSelect = local ? session.isLocalMultiSelect : session.isRemoteMultiSelect
        let selectedSet = local ? session.selectedLocalSet : session.selectedRemoteSet
        ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVStack(spacing: 0) {
                    ForEach(nav.entries) { entry in
                        fileRow(entry: entry, local: local, multiSelect: multiSelect, isSelected: selectedSet.contains(entry.name))
                            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                            .frame(minHeight: 22)
                            .background(rowBackground(isSelected: selectedSet.contains(entry.name)))
                            .background(rowFrameCollector(entry: entry, local: local))
                    }
                }

                // 框选矩形可视化(纯展示,不参与 hit-testing;每栏独立)
                // 必须放在 ScrollView 内部,与条目共享同一 content 坐标空间,
                // 避免 .overlay 的 clip 坐标系与 content 坐标系不一致导致错位。
                let rect = local ? localDragRect : remoteDragRect
                if let rect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if nav.isLoading && nav.entries.isEmpty {
                ProgressView()
                    .scaleEffect(0.8)
            } else if nav.entries.isEmpty {
                Text("空目录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onPreferenceChange(FileRowFrameKey.self) {
            if local { localFileRowFrames = $0 } else { remoteFileRowFrames = $0 }
        }
        #if os(macOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("filePaneSpace"))
                .onChanged { value in
                    if local {
                        if localDragRect == nil {
                            localDragBaseSelection = session.selectedLocalSet
                            session.isLocalMultiSelect = true
                        }
                        localDragRect = CGRect(origin: value.startLocation, end: value.location)
                    } else {
                        if remoteDragRect == nil {
                            remoteDragBaseSelection = session.selectedRemoteSet
                            session.isRemoteMultiSelect = true
                        }
                        remoteDragRect = CGRect(origin: value.startLocation, end: value.location)
                    }
                    updateSelectionFromDrag(local: local, entries: nav.entries)
                }
                .onEnded { _ in
                    if local {
                        localDragRect = nil
                        localDragBaseSelection = []
                    } else {
                        remoteDragRect = nil
                        remoteDragBaseSelection = []
                    }
                }
        )
        #endif
        .coordinateSpace(name: "filePaneSpace")
    }

    /// 行高亮背景:选中时填充系统高亮或强调色,未选中时透明。
    private func rowBackground(isSelected: Bool) -> some View {
        isSelected
            ? Color.accentColor.opacity(0.15)
            : Color.clear
    }

    /// 当前是否按下 Command 键(macOS 专用;iPadOS 始终返回 false)。
    private var isCommandKeyPressed: Bool {
        #if os(macOS)
        NSApp.currentEvent?.modifierFlags.contains(.command) == true
        #else
        false
        #endif
    }

    /// 处理条目单击:根据是否多选模式与 ⌘ 键状态更新选中集合。
    private func handleRowTap(entry: FileEntry, local: Bool, multiSelect: Bool) {
        let append = multiSelect || isCommandKeyPressed
        if local {
            session.selectLocal(entry.name, append: append)
        } else {
            session.selectRemote(entry.name, append: append)
        }
    }

    /// 文件行:复选框(多选模式)+ 图标 + 名称 + 大小 + 修改时间。
    private func fileRow(entry: FileEntry, local: Bool, multiSelect: Bool, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if multiSelect {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
            }
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 20)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(entry.isDirectory ? "—" : formatBytes(entry.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if horizontalSizeClass != .compact {
                Text(entry.modified)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
        }
        .font(.callout)
        // 让整行都是可点击区域,确保单击选中可靠。
        .contentShape(Rectangle())
        .onTapGesture {
            handleRowTap(entry: entry, local: local, multiSelect: multiSelect)
        }
        // 目录行附加双击进入手势;与单击手势互不阻塞。
        .applyIf(entry.isDirectory) {
            $0.simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    Task {
                        local ? await session.enterLocal(entry.name) : await session.enterRemote(entry.name)
                    }
                }
            )
        }
        .contextMenu { fileContextMenu(entry: entry, local: local, multiSelect: multiSelect) }
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

    /// 文件/目录右键(macOS)/长按(iPadOS)菜单。
    @ViewBuilder
    private func fileContextMenu(entry: FileEntry, local: Bool, multiSelect: Bool) -> some View {
        if multiSelect {
            EmptyView()
        } else {
            if entry.isDirectory {
                Button {
                    Task {
                        local ? await session.enterLocal(entry.name) : await session.enterRemote(entry.name)
                    }
                } label: {
                    Label("进入", systemImage: "arrow.forward")
                }
            }
            if local {
                Button {
                    session.selectLocal(entry.name)
                    Task { await session.uploadSelected() }
                } label: {
                    Label("上传", systemImage: "arrow.up")
                }
            } else {
                Button {
                    session.selectRemote(entry.name)
                    Task { await session.downloadSelected() }
                } label: {
                    Label("下载", systemImage: "arrow.down")
                }
            }
            Button(role: .destructive) {
                deleteCandidate = (entry, local)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 栏底:单选模式显示「上传 →」/「← 下载」;
    /// 本地/远程多选模式显示选中数量与批量上传/下载按钮。
    private func paneFoot(local: Bool) -> some View {
        HStack(spacing: 8) {
            let isMultiSelect = local ? session.isLocalMultiSelect : session.isRemoteMultiSelect
            let selectedSet = local ? session.selectedLocalSet : session.selectedRemoteSet
            let count = selectedSet.count
            if isMultiSelect {
                Text("已选 \(count) 项")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(local ? "上传 →" : "← 下载") {
                    Task {
                        let tasks = local ? await session.uploadSelected() : await session.downloadSelected()
                        if let first = tasks {
                            toast.show("已加入批量\(local ? "上传" : "下载")队列：\(first.name) 等 \(count) 项")
                            panelOpen = true
                            local ? session.toggleLocalMultiSelect() : session.toggleRemoteMultiSelect()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(count == 0)
            } else if let selection = selectedSet.first {
                Text("已选：")
                    .foregroundStyle(.secondary)
                + Text(selection)
                    .bold()
                Spacer()
                Button(local ? "上传 →" : "← 下载") {
                    Task {
                        let task = local ? await session.uploadSelected() : await session.downloadSelected()
                        if let task {
                            toast.show((local ? "已加入上传队列：" : "已加入下载队列：") + task.name)
                            panelOpen = true
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(local ? "单击选中 · 双击文件夹进入" : "单击选中 · 双击文件夹进入")
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
        guard model.configRecord(for: host.id) != nil else {
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

    // MARK: - 框选多选(每栏独立状态)

    /// 本地栏拖拽框。
    @State private var localDragRect: CGRect? = nil
    /// 远程栏拖拽框。
    @State private var remoteDragRect: CGRect? = nil
    /// 本地栏各行边界框,由 PreferenceKey 收集。
    @State private var localFileRowFrames: [String: CGRect] = [:]
    /// 远程栏各行边界框,由 PreferenceKey 收集。
    @State private var remoteFileRowFrames: [String: CGRect] = [:]
    /// 本地栏拖拽开始时的基线选中集合(用于 ⌘ 键追加模式)。
    @State private var localDragBaseSelection: Set<String> = []
    /// 远程栏拖拽开始时的基线选中集合(用于 ⌘ 键追加模式)。
    @State private var remoteDragBaseSelection: Set<String> = []

    /// 根据当前拖拽框与条目框架更新选中集合。
    /// 不按 ⌘ 时:选中集合 = 框内条目(覆盖基线)。
    /// 按 ⌘ 时:选中集合 = 基线 ∪ 框内条目(基线条目保留,框内条目追加)。
    private func updateSelectionFromDrag(local: Bool, entries: [FileEntry]) {
        let rect = local ? localDragRect : remoteDragRect
        guard let rect else { return }
        let frames = local ? localFileRowFrames : remoteFileRowFrames
        let baseSelection = local ? localDragBaseSelection : remoteDragBaseSelection
        let isAppend = isCommandKeyPressed
        let inRectNames = Set(entries.compactMap { entry -> String? in
            guard let frame = frames[entry.name] else { return nil }
            return rect.intersects(frame) ? entry.name : nil
        })
        let finalSelection = isAppend ? baseSelection.union(inRectNames) : inRectNames
        if local {
            session.selectedLocalSet = finalSelection
        } else {
            session.selectedRemoteSet = finalSelection
        }
    }
}

/// 收集每行在文件面板坐标系中的边界框,用于框选计算。
struct FileRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 按条件应用修饰符,避免为 if/else 生成不同的返回类型。
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension CGRect {
    /// 由两个 CGPoint 构造矩形,自动处理负宽高。
    init(origin: CGPoint, end: CGPoint) {
        let x = min(origin.x, end.x)
        let y = min(origin.y, end.y)
        let width = abs(end.x - origin.x)
        let height = abs(end.y - origin.y)
        self.init(x: x, y: y, width: width, height: height)
    }
}

/// 覆盖确认弹窗:并排展示源文件与目标文件的大小、最后修改时间。
struct OverwriteConfirmationSheet: View {
    let conflict: PendingConflict
    let onResolve: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("“\(conflict.name)” 已存在")
                .font(.headline)

            HStack(alignment: .top, spacing: 24) {
                fileColumn(title: "源文件", size: conflict.sourceSize, date: conflict.sourceDate)
                Divider().frame(height: 60)
                fileColumn(title: "目标文件", size: conflict.targetSize, date: conflict.targetDate)
            }

            HStack(spacing: 16) {
                Button("跳过", role: .cancel) {
                    onResolve(false)
                    dismiss()
                }

                Button("覆盖") {
                    onResolve(true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func fileColumn(title: String, size: UInt64, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(formatBytes(size))
                .font(.system(.body, design: .rounded))
            Text(date.map(formattedDate) ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        return formatter.string(from: date)
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
