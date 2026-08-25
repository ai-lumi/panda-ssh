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
    @State private var failure: ConnectionFailure = .timeout
    /// 连接尝试序号:重试时 +1,驱动 .task 重跑连接动画。
    @State private var attempt = 0
    @State private var presentationState = SFTPPresentationState(layout: .dualPane)
    @State private var transferPresentationState = TransferPanelPresentationState()
    /// 待确认删除的条目名称列表;nil 表示未触发删除确认。
    /// 多选右键删除时含多个名称,单选/未选中右键时仅 1 个。
    @State private var deleteCandidate: (names: [String], local: Bool)? = nil
    /// 本地/远程路径导航编辑态:点击面包屑进入输入,回车跳转、Esc/失焦取消(item 7)。
    @State private var localPathEditing = false
    @State private var localPathInput = ""
    @State private var remotePathEditing = false
    @State private var remotePathInput = ""
    @FocusState private var localPathFocused: Bool
    @FocusState private var remotePathFocused: Bool

    private var minimumInteractiveLength: Double {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    init(tab: WorkspaceTab, host: HostEntry, transfers: TransferStore) {
        self.tab = tab
        self.host = host
        // 会话与面板共享同一个全局 TransferStore(与原型全局传输列表一致)
        _session = StateObject(wrappedValue: SftpSessionStore(host: host, transfers: transfers))
    }

    /// 单文件与批量冲突弹窗合并为同一个 sheet：优先展示单文件确认，
    /// 关闭时清除对应来源的等待状态。
    private var activeConflictBinding: Binding<PendingConflict?> {
        Binding(
            get: { session.pendingConflict ?? session.batchPendingConflict },
            set: { newValue in
                if newValue == nil {
                    session.pendingConflict = nil
                    session.batchPendingConflict = nil
                }
            }
        )
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
                        failure: failure,
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
        .sheet(item: activeConflictBinding) { conflict in
            OverwriteConfirmationSheet(conflict: conflict) { overwrite in
                if session.pendingConflict?.id == conflict.id {
                    session.resolveConflict(overwrite: overwrite)
                } else {
                    session.resolveBatchConflict(overwrite: overwrite)
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

    // MARK: - 响应式文件浏览器

    private var browser: some View {
        GeometryReader { geometry in
            let policy = layoutPolicy(availableWidth: geometry.size.width)
            browserSurface(policy: policy)
                .onAppear {
                    presentationState.updateLayout(policy.sftpPresentation)
                    transferPresentationState.updatePresentation(policy.transferPresentation)
                }
                .onChange(of: policy.sftpPresentation) { _, presentation in
                    presentationState.updateLayout(presentation)
                }
                .onChange(of: policy.transferPresentation) { _, presentation in
                    transferPresentationState.updatePresentation(presentation)
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
                    let result: (deleted: Int, failed: [(name: String, error: String)])
                    if candidate.local {
                        result = await session.deleteLocalBatch(names: candidate.names)
                    } else {
                        result = await session.deleteRemoteBatch(names: candidate.names)
                    }
                    if result.failed.isEmpty {
                        toast.show(candidate.names.count > 1 ? "已删除 \(result.deleted) 项" : "已删除 \(candidate.names[0])")
                    } else if result.deleted > 0 {
                        toast.show("已删除 \(result.deleted) 项，\(result.failed.count) 项失败")
                    } else {
                        let details = result.failed.map { "\($0.name): \($0.error)" }.joined(separator: "；")
                        toast.show("删除失败：\(details)")
                    }
                }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        }, message: {
            if let candidate = deleteCandidate {
                if candidate.names.count > 1 {
                    Text("确定要删除 \(candidate.names.count) 项吗？此操作不可撤销。")
                } else {
                    Text("确定要删除「\(candidate.names[0])」吗？此操作不可撤销。")
                }
            }
        })
    }

    @ViewBuilder
    private func browserSurface(policy: WorkspaceLayoutPolicy) -> some View {
        #if os(macOS)
        ZStack {
            browserColumns(policy: policy)

            if transferPresentationState.isPresented {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { transferPresentationState.dismiss() }
                    .transition(.opacity)

                HStack(spacing: 0) {
                    Spacer()
                    TransferPanelView(store: transfers)
                        .frame(width: 340)
                        .background(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 16, x: -4, y: 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transferPresentationState.isPresented)
        #else
        browserColumns(policy: policy)
            .inspector(isPresented: panelBinding(for: .inspector, policy: policy)) {
                TransferPanelView(store: transfers)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
            .sheet(isPresented: panelBinding(for: .sheet, policy: policy)) {
                NavigationStack {
                    TransferPanelView(store: transfers)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { transferPresentationState.dismiss() }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        #endif
    }

    private func browserColumns(policy: WorkspaceLayoutPolicy) -> some View {
        VStack(spacing: 0) {
            toolbar(policy: policy)
            Divider()
            if policy.sftpPresentation == .dualPane {
                HStack(spacing: 0) {
                    pane(local: true)
                    Divider()
                    pane(local: false)
                }
            } else {
                Picker("文件位置", selection: Binding(
                    get: { presentationState.selectedPane },
                    set: { presentationState.select($0) }
                )) {
                    Text("本地").tag(SFTPPresentationState.Pane.local)
                    Text("远程").tag(SFTPPresentationState.Pane.remote)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("文件位置")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                pane(local: presentationState.selectedPane == .local)
            }
        }
    }

    private func layoutPolicy(availableWidth: Double) -> WorkspaceLayoutPolicy {
        #if os(macOS)
        return WorkspaceLayoutPolicy.resolve(
            platform: .macOS,
            horizontalSizeClass: .unspecified,
            availableWidth: availableWidth
        )
        #else
        let sizeClass: WorkspaceLayoutPolicy.HorizontalSizeClass
        switch horizontalSizeClass {
        case .compact: sizeClass = .compact
        case .regular: sizeClass = .regular
        default: sizeClass = .unspecified
        }
        return WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: sizeClass,
            availableWidth: availableWidth
        )
        #endif
    }

    #if os(iOS)
    private func panelBinding(
        for presentation: WorkspaceLayoutPolicy.TransferPresentation,
        policy: WorkspaceLayoutPolicy
    ) -> Binding<Bool> {
        Binding(
            get: {
                transferPresentationState.isPresented
                    && transferPresentationState.presentation == presentation
                    && policy.transferPresentation == presentation
            },
            set: { if !$0 { transferPresentationState.dismiss() } }
        )
    }
    #endif

    private func toolbar(policy: WorkspaceLayoutPolicy) -> some View {
        HStack(spacing: 8) {
            Label("SFTP · \(host.username)@\(host.address)", systemImage: "folder")
                .font(.callout.bold())
            Spacer()
            Button {
                transferPresentationState.toggle(using: policy.transferPresentation)
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
            .frame(minHeight: minimumInteractiveLength)
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

    /// 栏头:标题(点击回根目录) + 返回上级 + 面包屑(可点击编辑路径) + 右侧操作按钮。
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
            // 面包屑:点击进入路径输入态;输入态展示 TextField,回车跳转、Esc/失焦取消(item 7)。
            pathEditor(nav: nav, local: local)
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

    /// 面包屑 / 路径输入切换:默认展示面包屑,点击切为 TextField。
    @ViewBuilder
    private func pathEditor(nav: FilePaneNavigator, local: Bool) -> some View {
        let editing = local ? localPathEditing : remotePathEditing
        if editing {
            TextField("输入路径", text: local ? $localPathInput : $remotePathInput)
                .font(.caption)
                .textFieldStyle(.plain)
                .focused(local ? $localPathFocused : $remotePathFocused)
                .onSubmit {
                    let target = local ? localPathInput : remotePathInput
                    Task {
                        let ok = local ? await session.navigateLocal(to: target) : await session.navigateRemote(to: target)
                        if !ok { toast.show("无法访问路径：\(target)") }
                        endPathEditing(local: local)
                    }
                }
                #if os(macOS)
                .onExitCommand { endPathEditing(local: local) }
                #endif
                .onChange(of: local ? localPathFocused : remotePathFocused) { _, focused in
                    // 失焦时退出编辑态、回到面包屑(不跳转)。
                    if !focused { endPathEditing(local: local) }
                }
                .onAppear {
                    if local { localPathFocused = true } else { remotePathFocused = true }
                }
        } else {
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
            .contentShape(Rectangle())
            .onTapGesture { startPathEditing(nav: nav, local: local) }
        }
    }

    private func startPathEditing(nav: FilePaneNavigator, local: Bool) {
        if local {
            localPathInput = nav.path
            localPathEditing = true
        } else {
            remotePathInput = nav.path
            remotePathEditing = true
        }
    }

    private func endPathEditing(local: Bool) {
        if local { localPathEditing = false } else { remotePathEditing = false }
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
        let tasks = await session.upload(localPaths: picked.paths)
        if let first = tasks.first {
            toast.show("已加入批量上传队列：\(first.name) 等 \(tasks.count) 项")
            transferPresentationState.present(using: transferPresentationState.presentation)
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
                            .frame(minHeight: minimumInteractiveLength)
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
                        session.localAnchor = anchorFromSelection(entries: nav.entries, selected: session.selectedLocalSet)
                    } else {
                        remoteDragRect = nil
                        remoteDragBaseSelection = []
                        session.remoteAnchor = anchorFromSelection(entries: nav.entries, selected: session.selectedRemoteSet)
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

    /// 当前是否按下 Shift 键(macOS 专用;iPadOS 始终返回 false)。
    private var isShiftKeyPressed: Bool {
        #if os(macOS)
        NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        #else
        false
        #endif
    }

    /// 处理条目单击:根据 Shift/⌘ 修饰键与多选模式更新选中集合。
    /// - Shift+单击:从 anchor 到当前条目的范围选择。
    /// - ⌘+Shift+单击:将范围追加到当前选中集合。
    /// - 无修饰键/仅 ⌘:保持原有单选/追加行为。
    private func handleRowTap(entry: FileEntry, local: Bool, multiSelect: Bool) {
        if isShiftKeyPressed {
            let anchor = local ? session.localAnchor : session.remoteAnchor
            if isCommandKeyPressed {
                if let anchor = anchor {
                    local
                        ? session.appendLocalRange(from: anchor, to: entry.name)
                        : session.appendRemoteRange(from: anchor, to: entry.name)
                } else {
                    // 无 anchor 时 ⌘+Shift+单击回退为追加单选。
                    local
                        ? session.selectLocal(entry.name, append: true)
                        : session.selectRemote(entry.name, append: true)
                }
            } else {
                if let anchor = anchor {
                    local
                        ? session.selectLocalRange(from: anchor, to: entry.name)
                        : session.selectRemoteRange(from: anchor, to: entry.name)
                } else {
                    // 无 anchor 时 Shift+单击回退为单选并设立 anchor。
                    local
                        ? session.selectLocal(entry.name, append: false)
                        : session.selectRemote(entry.name, append: false)
                }
            }
            return
        }
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
        // 双击:目录进入、文件触发传输(item 6);与单击选中手势互不阻塞。
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                Task {
                    local ? await session.doubleClickLocal(entry: entry) : await session.doubleClickRemote(entry: entry)
                }
            }
        )
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
    /// 多选模式下右键选中集合内条目 → 菜单文案含数量、action 作用于整个选中集合;
    /// 右键未选中条目 → action 先置为唯一选中再执行(item 5)。
    @ViewBuilder
    private func fileContextMenu(entry: FileEntry, local: Bool, multiSelect: Bool) -> some View {
        let selectedSet = local ? session.selectedLocalSet : session.selectedRemoteSet
        let count = selectedSet.count
        let collective = multiSelect && selectedSet.contains(entry.name) && count > 1
        let actionLabel = { (verb: String) -> String in collective ? "\(verb) \(count) 项" : verb }
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
                Task { await session.contextUpload(entry: entry) }
            } label: {
                Label(actionLabel("上传"), systemImage: "arrow.up")
            }
        } else {
            Button {
                Task { await session.contextDownload(entry: entry) }
            } label: {
                Label(actionLabel("下载"), systemImage: "arrow.down")
            }
        }
        Button(role: .destructive) {
            // 多选右键选中集合内条目 → 删除整个集合;否则仅删除右键条目(item 5 修复)。
            if collective {
                deleteCandidate = (Array(selectedSet), local)
            } else {
                // 右键未选中条目 → 先置为唯一选中(与上传/下载一致)
                if !selectedSet.contains(entry.name) {
                    if local { session.selectLocal(entry.name, append: false) }
                    else { session.selectRemote(entry.name, append: false) }
                }
                deleteCandidate = ([entry.name], local)
            }
        } label: {
            Label(actionLabel("删除"), systemImage: "trash")
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
                            transferPresentationState.present(using: transferPresentationState.presentation)
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
                            transferPresentationState.present(using: transferPresentationState.presentation)
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
        .frame(minHeight: max(36, minimumInteractiveLength))
    }

    // MARK: - 真实连接

    private func startRealConnection() async {
        guard model.configRecord(for: host.id) != nil else {
            phase = .failed
            return
        }
        if gate.requestCredentialsIfNeeded(for: host) { return }
        let secrets = CredentialResolver.localStore()
            .connectionSecrets(for: host, manualSecret: gate.manualSecret)
        guard let secrets else {
            _ = gate.requestCredentialsIfNeeded(for: host)
            return
        }
        if let error = await session.connect(password: secrets.password, passphrase: secrets.passphrase) {
            let classified = ConnectionFailure(error: error)
            if classified == .missingCredential {
                gate.requireCredentialInput()
            } else if let key = classified.presentedHostKey,
                      gate.requireTofuConfirmation(key) {
                model.backend.cachePresentedKey(key, for: host.id)
                attempt += 1
                phase = .connecting
            } else {
                failure = classified
                phase = .failed
            }
            return
        }
        let localOK = await session.localPane.reload()
        let remoteOK = await session.remotePane.reload()
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        if localOK && remoteOK {
            phase = .connected
        } else {
            failure = session.remotePane.lastError.map(ConnectionFailure.init(error:)) ?? .other("无法读取远程目录。")
            if failure == .missingCredential {
                gate.requireCredentialInput()
            } else {
                phase = .failed
            }
        }
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

    /// 根据最终选中集合按列表顺序返回第一个被选中的条目名，作为范围选择 anchor。
    /// 空集合时返回 nil。
    private func anchorFromSelection(entries: [FileEntry], selected: Set<String>) -> String? {
        entries.first { selected.contains($0.name) }?.name
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
