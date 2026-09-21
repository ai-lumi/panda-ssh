// =============================================================================
// SftpTabView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了 SFTP 标签页 (SftpTabView)，是工作区中展示 SFTP 文件浏览器的核心视图。
// 主要功能：
//   1. 连接门控：与终端标签页一致，打开时先检查主机密钥信任、密码输入等。
//   2. 双栏文件浏览器：左侧本地文件系统，右侧远程 SFTP 文件系统。
//   3. 响应式布局：根据可用宽度自动切换双栏/单栏模式（iPad 窄屏时为单栏 + 分段选择器）。
//   4. 文件操作：导航（进入子目录、返回上级、面包屑跳转）、上传、下载、删除。
//   5. 多选支持：单击选中、⌘+单击追加、Shift+单击范围选择、macOS 拖拽框选。
//   6. 右键菜单：进入、上传/下载、删除等操作。
//   7. 路径编辑：点击面包屑进入路径输入模式，回车跳转。
//   8. 覆盖确认弹窗：传输冲突时展示源文件与目标文件的详细信息。
//
// 主要类型：
//   - SftpTabView: SFTP 标签页主视图。
//   - OverwriteConfirmationSheet: 覆盖确认弹窗。
//   - FileRowFrameKey: PreferenceKey，收集每行的 frame 用于框选计算。
//   - View 扩展：sftpNavigationPointer（鼠标指针纠正）、applyIf（条件修饰符）。
//   - CGRect 扩展：由两点构造矩形。
// =============================================================================

import SwiftUI

/// SFTP 标签页:本地/远程文件浏览器，传输任务由全局页面统一管理。
/// 打开时先过连接门控(与终端一致),再经约 800ms 连接动画进入双栏;
/// 连接失败展示重试/关闭,与原型 errbox 一致。
struct SftpTabView: View {
    // ── 环境对象 ──
    /// AppModel: 应用全局状态模型
    @EnvironmentObject private var model: AppModel
    /// WorkspaceStore: 工作区数据仓库
    @EnvironmentObject private var workspace: WorkspaceStore
    /// ToastCenter: 轻提示消息中心（显示「已删除 xxx」等短暂通知）
    @EnvironmentObject private var toast: ToastCenter
    /// horizontalSizeClass: iPad 平台的水平尺寸类别（compact = 窄屏，regular = 宽屏）
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // ── 外部传入参数 ──
    /// 当前页签对象
    let tab: WorkspaceTab
    /// 当前连接的主机配置
    let host: HostEntry

    // ── 本地状态对象 ──
    /// 连接门控状态管理器
    @StateObject private var gate = PreconnectGate()
    /// SFTP 会话存储：管理 SFTP 连接、本地/远程文件导航、传输任务等
    @StateObject private var session: SftpSessionStore

    /// 连接阶段:connecting →(约 800ms)→ connected / failed。
    private enum Phase {
        // 连接中
        case connecting
        // 已连接（展示文件浏览器）
        case connected
        // 连接失败（展示错误信息和重试按钮）
        case failed
    }

    /// 当前连接阶段
    @State private var phase: Phase = .connecting
    /// 连接失败时的错误类型
    @State private var failure: ConnectionFailure = .timeout
    /// 连接尝试序号:重试时 +1,驱动 .task 重跑连接动画。
    @State private var attempt = 0
    /// 文件浏览器的呈现状态（双栏/单栏、选中面板等）
    @State private var presentationState = SFTPPresentationState(layout: .dualPane)
    /// 待确认删除的条目名称列表;nil 表示未触发删除确认。
    /// 多选右键删除时含多个名称,单选/未选中右键时仅 1 个。
    @State private var deleteCandidate: (names: [String], local: Bool)? = nil
    /// 本地路径导航编辑态:点击面包屑进入输入,回车跳转、Esc/失焦取消
    @State private var localPathEditing = false
    /// 本地路径输入框的文字
    @State private var localPathInput = ""
    /// 远程路径导航编辑态
    @State private var remotePathEditing = false
    /// 远程路径输入框的文字
    @State private var remotePathInput = ""
    /// 本地路径输入框是否获得焦点
    @FocusState private var localPathFocused: Bool
    /// 远程路径输入框是否获得焦点
    @FocusState private var remotePathFocused: Bool

    /// 最小交互高度：macOS 24pt（鼠标点击），iPadOS 44pt（手指触摸）
    private var minimumInteractiveLength: Double {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    /// 自定义初始化器：初始化 SftpSessionStore 并注入全局 TransferStore
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
            // get: 优先取单文件冲突，没有则取批量冲突
            get: { session.pendingConflict ?? session.batchPendingConflict },
            set: { newValue in
                if newValue == nil {
                    // 弹窗关闭时清除两种冲突状态
                    session.pendingConflict = nil
                    session.batchPendingConflict = nil
                }
            }
        )
    }

    /// 视图主体：根据连接阶段展示不同内容
    var body: some View {
        Group {
            if !gate.unlocked {
                // 门控对话框展示期间内容留空(取消即关标签)
                // Color.clear 占位，保持布局稳定
                Color.clear
            } else {
                switch phase {
                case .connecting:
                    // 连接中：显示进度指示器和连接地址
                    ConnectingRow(host: host)
                case .failed:
                    // 连接失败：显示错误信息、重试和关闭按钮
                    ConnectFailureView(
                        host: host,
                        failure: failure,
                        onRetry: {
                            // 重试：断开当前连接，增加尝试序号，重新进入连接中状态
                            session.disconnect()
                            attempt += 1
                            phase = .connecting
                        },
                        onClose: { workspace.close(tabID: tab.id) }
                    )
                    // .padding(24) 错误视图四周留 24pt 边距
                    .padding(24)
                case .connected:
                    // 已连接：显示文件浏览器
                    browser
                }
            }
        }
        // .sheet 覆盖确认弹窗：当有文件冲突时弹出
        .sheet(item: activeConflictBinding) { conflict in
            OverwriteConfirmationSheet(conflict: conflict) { overwrite in
                // 根据冲突来源调用对应的解决方法
                if session.pendingConflict?.id == conflict.id {
                    session.resolveConflict(overwrite: overwrite)
                } else {
                    session.resolveBatchConflict(overwrite: overwrite)
                }
            }
        }
        // .frame(maxWidth: .infinity, maxHeight: .infinity) 撑满整个可用区域
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .onAppear 视图首次出现时执行初始化
        .onAppear {
            // 注册 SFTP 会话到 workspace
            workspace.registerSftp(session, for: tab.id)
            // 设置重连回调：由页签右键菜单的「重新连接」触发
            session.onReconnectRequested = {
                session.disconnect()
                attempt += 1
                phase = .connecting
            }
            // 上报初始连接状态
            workspace.reportConnectionStatus(status(for: phase), forTabID: tab.id)
            if model.usesMockBackend {
                // Mock 后端：使用演示数据
                session.useDemoSource()
            }
            // 评估连接门控
            evaluateGate()
        }
        .onDisappear {
            // 仅页面切换时标签仍存在，必须保留其专属 SFTP 连接。
            guard !workspace.tabs.contains(where: { $0.id == tab.id }) else { return }
            // 标签真正移除时断开连接
            session.disconnect()
            workspace.reportConnectionStatus(.inactive, forTabID: tab.id)
        }
        // .onChange 监听连接阶段变化，同步更新状态
        .onChange(of: phase) { _, newPhase in
            workspace.reportConnectionStatus(status(for: newPhase), forTabID: tab.id)
        }
        // .preconnectSheets 挂载连接门控相关的 sheet
        .preconnectSheets(gate: gate, host: host, tabID: tab.id)
        // .task 连接任务：门控通过后启动连接
        .task(id: "\(attempt)-\(gate.unlocked)") {
            guard gate.unlocked, phase == .connecting else { return }
            if model.usesMockBackend {
                // Mock 后端：等待 800ms 模拟连接延迟
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                // 根据主机演示状态决定连接成功或失败
                phase = host.demo == .offline ? .failed : .connected
            } else {
                // 真实后端：启动 SFTP 连接
                await startRealConnection()
            }
        }
    }

    /// 将连接阶段映射为工作区连接状态
    private func status(for phase: Phase) -> WorkspaceConnectionStatus {
        switch phase {
        // 连接中
        case .connecting: return .connecting
        // 已连接
        case .connected: return .connected
        // 失败
        case .failed: return .failed
        }
    }

    // MARK: - 响应式文件浏览器

    /// 文件浏览器主视图：根据可用宽度自动切换双栏/单栏布局
    private var browser: some View {
        // GeometryReader 获取可用区域宽度，用于决定布局策略
        GeometryReader { geometry in
            // 根据可用宽度计算布局策略
            let policy = layoutPolicy(availableWidth: geometry.size.width)
            browserColumns(policy: policy)
                // .onAppear 初始化时设置布局
                .onAppear {
                    presentationState.updateLayout(policy.sftpPresentation)
                }
                // .onChange 布局策略变化时更新呈现状态
                .onChange(of: policy.sftpPresentation) { _, presentation in
                    presentationState.updateLayout(presentation)
                }
        }
        // .alert 删除确认对话框
        .alert("确认删除", isPresented: .init(
            // get: deleteCandidate 非 nil 时显示对话框
            get: { deleteCandidate != nil },
            // set: 对话框关闭时清除 deleteCandidate
            set: { if !$0 { deleteCandidate = nil } }
        ), actions: {
            // 「删除」按钮：destructive 角色（红色高亮）
            Button("删除", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                // 异步执行批量删除
                Task {
                    let result: (deleted: Int, failed: [(name: String, error: String)])
                    if candidate.local {
                        // 删除本地文件
                        result = await session.deleteLocalBatch(names: candidate.names)
                    } else {
                        // 删除远程文件
                        result = await session.deleteRemoteBatch(names: candidate.names)
                    }
                    // 根据删除结果显示不同的 toast 消息
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
            // 「取消」按钮：关闭对话框
            Button("取消", role: .cancel) { deleteCandidate = nil }
        }, message: {
            // 对话框消息：根据删除数量显示不同文案
            if let candidate = deleteCandidate {
                if candidate.names.count > 1 {
                    Text("确定要删除 \(candidate.names.count) 项吗？此操作不可撤销。")
                } else {
                    Text("确定要删除「\(candidate.names[0])」吗？此操作不可撤销。")
                }
            }
        })
    }

    /// 文件浏览器列布局：双栏模式显示本地+远程，单栏模式用分段选择器切换
    private func browserColumns(policy: WorkspaceLayoutPolicy) -> some View {
        VStack(spacing: 0) {
            if policy.sftpPresentation == .dualPane {
                // 双栏模式：本地和远程并排显示，中间用 Divider 分隔
                HStack(spacing: 0) {
                    // 左侧：本地文件面板
                    pane(local: true)
                    // 中间分隔线
                    Divider()
                    // 右侧：远程文件面板
                    pane(local: false)
                }
            } else {
                // 单栏模式：顶部分段选择器切换本地/远程
                Picker("文件位置", selection: Binding(
                    get: { presentationState.selectedPane },
                    set: { presentationState.select($0) }
                )) {
                    Text("本地").tag(SFTPPresentationState.Pane.local)
                    Text("远程").tag(SFTPPresentationState.Pane.remote)
                }
                // .pickerStyle(.segmented) 分段选择器样式（iOS 风格的胶囊按钮组）
                .pickerStyle(.segmented)
                // .labelsHidden() 隐藏 Picker 的标签文字
                .labelsHidden()
                .accessibilityLabel("文件位置")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                // 只显示选中面板的内容
                pane(local: presentationState.selectedPane == .local)
            }
        }
    }

    /// 根据可用宽度和平台计算布局策略
    private func layoutPolicy(availableWidth: Double) -> WorkspaceLayoutPolicy {
        #if os(macOS)
        // macOS: 始终使用 .unspecified 尺寸类别（不依赖 horizontalSizeClass）
        return WorkspaceLayoutPolicy.resolve(
            platform: .macOS,
            horizontalSizeClass: .unspecified,
            availableWidth: availableWidth
        )
        #else
        // iPadOS: 根据 horizontalSizeClass 决定布局
        let sizeClass: WorkspaceLayoutPolicy.HorizontalSizeClass
        switch horizontalSizeClass {
        // 窄屏（如 iPad 分屏）
        case .compact: sizeClass = .compact
        // 宽屏（如 iPad 全屏）
        case .regular: sizeClass = .regular
        // 未指定
        default: sizeClass = .unspecified
        }
        return WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: sizeClass,
            availableWidth: availableWidth
        )
        #endif
    }

    // MARK: - 单栏(本地 / 远程)

    /// 单栏文件面板：标题栏 + 文件列表 + 底部状态栏
    private func pane(local: Bool) -> some View {
        // 根据 local 参数选择本地或远程的导航器
        let nav = local ? session.localPane : session.remotePane
        return VStack(spacing: 0) {
            // 顶部标题栏：标题 + 返回上级 + 面包屑 + 操作按钮
            paneHead(nav: nav, local: local)
            Divider()
            // 中间文件列表
            fileList(nav: nav, local: local)
            Divider()
            // 底部状态栏：选中信息 + 上传/下载按钮
            paneFoot(local: local)
        }
        // .frame(maxWidth: .infinity, maxHeight: .infinity) 撑满可用区域
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 栏头:标题(点击回根目录) + 返回上级 + 面包屑(可点击编辑路径) + 右侧操作按钮。
    private func paneHead(nav: FilePaneNavigator, local: Bool) -> some View {
        // HStack 水平排列所有栏头元素，间距 6pt
        HStack(spacing: 6) {
            // ── 标题按钮：点击回到根目录 ──
            Button {
                Task {
                    local ? await session.navigateLocal(to: nav.root) : await session.navigateRemote(to: nav.root)
                }
            } label: {
                // 标题文字：本地显示「本地」，远程显示「远程 — 主机名」
                Text(local ? "本地" : "远程 — \(host.name)")
                    // .font(.caption.bold()) caption 字号 + 粗体
                    .font(.caption.bold())
                    // .padding(.horizontal, 8) 左右留 8pt 内边距
                    .padding(.horizontal, 8)
                    // .frame(height: 20) 固定高度 20pt
                    .frame(height: 20)
                    // .contentShape 定义点击区域为圆角矩形
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            // .sftpNavigationPointer() macOS 上设置鼠标指针为箭头（纠正从文本区域遗留的指针）
            .sftpNavigationPointer()
            // .foregroundStyle(.secondary) 使用二级灰色文字
            .foregroundStyle(.secondary)
            // .background 淡灰色圆角背景（4% 不透明度）
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            // .overlay 细微的描边（10% 不透明度，0.5pt 宽）
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .accessibilityLabel("返回顶级目录")

            // ── 返回上级按钮：chevron.left 图标 ──
            Button {
                Task {
                    local ? await session.goUpLocal() : await session.goUpRemote()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption)
                    .frame(width: 24, height: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .sftpNavigationPointer()
            // 可以返回上级时用主色，不能返回时用半透明灰色
            .foregroundStyle(nav.canGoUp ? Color.primary : Color.secondary.opacity(0.4))
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            // 不能返回上级时禁用按钮
            .disabled(!nav.canGoUp)
            .accessibilityLabel("返回上级")

            // ── 面包屑 / 路径编辑器 ──
            pathEditor(nav: nav, local: local)

            // ── 刷新按钮：arrow.clockwise 图标 ──
            Button {
                Task {
                    local ? await session.localPane.reload() : await session.remotePane.reload()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .frame(width: 24, height: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .sftpNavigationPointer()
            .foregroundStyle(.secondary)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .accessibilityLabel("刷新当前目录")

            // ── 右侧操作按钮（选择/完成） ──
            paneHeadActions(local: local)
        }
        // .padding(.horizontal, 8) 栏头左右留 8pt 内边距
        .padding(.horizontal, 8)
        // .padding(.vertical, 6) 栏头上下留 6pt 内边距
        .padding(.vertical, 6)
    }

    /// 面包屑 / 路径输入切换:默认展示面包屑,点击切为 TextField。
    @ViewBuilder
    private func pathEditor(nav: FilePaneNavigator, local: Bool) -> some View {
        let editing = local ? localPathEditing : remotePathEditing
        if editing {
            // ── 路径编辑模式：TextField + 前往按钮 ──
            HStack(spacing: 4) {
                TextField("输入绝对路径，例如 /var/log", text: local ? $localPathInput : $remotePathInput)
                    // .font(.caption) caption 字号
                    .font(.caption)
                    // .textFieldStyle(.plain) 朴素文本框样式（无边框）
                    .textFieldStyle(.plain)
                    // .autocorrectionDisabled() 禁用自动纠正（路径不应被自动修改）
                    .autocorrectionDisabled()
                    #if os(iOS)
                    // iOS: 禁用自动大写（路径区分大小写）
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel(local ? "本地目录路径" : "远程目录路径")
                    // .focused 绑定焦点状态
                    .focused(local ? $localPathFocused : $remotePathFocused)
                    // .onSubmit 回车键提交路径
                    .onSubmit {
                        submitPath(local: local)
                    }
                    #if os(macOS)
                    // macOS: Esc 键退出编辑模式
                    .onExitCommand { endPathEditing(local: local) }
                    #endif
                    .onChange(of: local ? localPathFocused : remotePathFocused) { _, focused in
                        // 失焦时退出编辑态、回到面包屑(不跳转)。
                        if !focused { endPathEditing(local: local) }
                    }
                    .onAppear {
                        // 出现时自动聚焦到文本框
                        if local { localPathFocused = true } else { remotePathFocused = true }
                    }
                // 前往按钮：arrow.right.circle 图标
                Button {
                    submitPath(local: local)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .frame(width: 24, height: 20)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .sftpNavigationPointer()
                .foregroundStyle(.secondary)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .accessibilityLabel("前往目录")
            }
        } else {
            // ── 面包屑模式：显示路径面包屑 + 编辑按钮 ──
            HStack(spacing: 4) {
                // 面包屑：水平滚动的路径段按钮
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        // 只有一个面包屑时直接显示路径文字（不可点击）
                        if nav.breadcrumbs.count == 1 {
                            Text(nav.path)
                                .font(.caption)
                        }
                        // 栏头左侧已经显示「本地」或「远程 — host.name」，
                        // 面包屑跳过 rootTitle，避免重复显示。
                        ForEach(Array(nav.breadcrumbs.dropFirst().enumerated()), id: \.element.path) { index, crumb in
                            // 非第一个面包屑前显示分隔符 "›"
                            if index > 0 {
                                Text("›")
                                    .foregroundStyle(.secondary)
                            }
                            // 面包屑按钮：点击跳转到该级目录
                            Button(crumb.title) {
                                Task {
                                    local ? await session.navigateLocal(to: crumb.path) : await session.navigateRemote(to: crumb.path)
                                }
                            }
                            .buttonStyle(.plain)
                            .sftpNavigationPointer()
                            .font(.caption)
                            // .fontWeight(.semibold) 半粗体，让面包屑文字更醒目
                            .fontWeight(.semibold)
                        }
                    }
                }
                // .contentShape(Rectangle()) 让整个滚动区域可点击
                .contentShape(Rectangle())
                .sftpNavigationPointer()
                // 点击面包屑区域进入路径编辑模式
                .onTapGesture { startPathEditing(nav: nav, local: local) }
                // 编辑按钮：pencil 图标
                Button {
                    startPathEditing(nav: nav, local: local)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .frame(width: 24, height: 20)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .sftpNavigationPointer()
                .foregroundStyle(.secondary)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .accessibilityLabel(local ? "编辑本地路径" : "编辑远程路径")
                // .help 鼠标悬停时显示完整路径的 tooltip
                .help(nav.path)
            }
        }
    }

    /// 提交路径输入：退出编辑模式，尝试导航到输入的路径
    private func submitPath(local: Bool) {
        let target = local ? localPathInput : remotePathInput
        endPathEditing(local: local)
        Task {
            let ok = local ? await session.navigateLocal(to: target) : await session.navigateRemote(to: target)
            let nav = local ? session.localPane : session.remotePane
            if !ok, let error = nav.lastError {
                // 导航失败时显示 toast 错误消息
                toast.show("无法访问路径：\(target)。\(error.localizedDescription)")
            }
        }
    }

    /// 进入路径编辑模式：将当前路径填入输入框
    private func startPathEditing(nav: FilePaneNavigator, local: Bool) {
        if local {
            localPathInput = nav.path
            localPathEditing = true
        } else {
            remotePathInput = nav.path
            remotePathEditing = true
        }
    }

    /// 退出路径编辑模式
    private func endPathEditing(local: Bool) {
        if local { localPathEditing = false } else { remotePathEditing = false }
    }

    /// 栏头右侧操作按钮：本地/远程的「选择/完成」多选切换按钮
    @ViewBuilder
    private func paneHeadActions(local: Bool) -> some View {
        if local {
            // 本地面板：多选切换按钮
            Button {
                session.toggleLocalMultiSelect()
            } label: {
                // 文字：多选模式下显示「完成」，普通模式下显示「选择」
                Text(session.isLocalMultiSelect ? "完成" : "选择")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .sftpNavigationPointer()
            .foregroundStyle(.secondary)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .accessibilityLabel(session.isLocalMultiSelect ? "完成选择" : "进入本地多选模式")

        } else {
            // 远程面板：多选切换按钮
            Button {
                session.toggleRemoteMultiSelect()
            } label: {
                Text(session.isRemoteMultiSelect ? "完成" : "选择")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .sftpNavigationPointer()
            .foregroundStyle(.secondary)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .accessibilityLabel(session.isRemoteMultiSelect ? "完成选择" : "进入多选模式")
        }
    }

    /// 文件列表:手动管理选中状态,提供与 Finder / Files App 一致的交互。
    /// - 单击条目高亮/选中;未按修饰键时单选互斥,按 ⌘ 时追加/取消多选。
    /// - 双击目录进入子目录。
    /// - 多选模式显示复选框。
    /// - macOS 支持鼠标拖拽框选(用 simultaneousGesture,不阻塞行的点击)。
    @ViewBuilder
    private func rowFrameCollector(entry: FileEntry, local: Bool) -> some View {
        // 只在拖拽框选激活时才收集行 frame，避免大目录下每行常驻 GeometryReader 的布局开销
        let dragActive = (local ? localDragRect : remoteDragRect) != nil
        if dragActive {
            // 拖拽激活：用 GeometryReader 收集此行在 filePaneSpace 坐标系中的 frame
            GeometryReader { geo in
                Color.clear.preference(
                    key: FileRowFrameKey.self,
                    value: [entry.name: geo.frame(in: .named("filePaneSpace"))]
                )
            }
        } else {
            // 拖拽未激活：用 Color.clear 占位（无布局开销）
            Color.clear
        }
    }

    /// 文件列表视图：ScrollView + LazyVStack + 框选矩形
    @ViewBuilder
    private func fileList(nav: FilePaneNavigator, local: Bool) -> some View {
        let multiSelect = local ? session.isLocalMultiSelect : session.isRemoteMultiSelect
        let selectedSet = local ? session.selectedLocalSet : session.selectedRemoteSet
        ScrollView {
            // ZStack 叠加文件行列表和框选矩形
            ZStack(alignment: .topLeading) {
                // LazyVStack 懒加载文件行（只渲染可见行，优化大目录性能）
                LazyVStack(spacing: 0) {
                    ForEach(nav.entries) { entry in
                        fileRow(entry: entry, local: local, multiSelect: multiSelect, isSelected: selectedSet.contains(entry.name))
                            // .padding 每行上下 3pt、左右 10pt 内边距
                            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                            // .frame(minHeight:) 确保每行有足够的最小高度（可点击区域）
                            .frame(minHeight: minimumInteractiveLength)
                            // .background 选中行显示高亮背景
                            .background(rowBackground(isSelected: selectedSet.contains(entry.name)))
                            // .background 拖拽时收集行 frame
                            .background(rowFrameCollector(entry: entry, local: local))
                    }
                }

                // 框选矩形可视化(纯展示,不参与 hit-testing;每栏独立)
                let rect = local ? localDragRect : remoteDragRect
                if let rect {
                    Rectangle()
                        // .fill 半透明蓝色填充（15% 不透明度的主题色）
                        .fill(Color.accentColor.opacity(0.15))
                        // .stroke 蓝色描边（50% 不透明度，1pt 宽）
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        // .position 定位矩形中心点
                        .position(x: rect.midX, y: rect.midY)
                        // .allowsHitTesting(false) 框选矩形不拦截点击事件
                        .allowsHitTesting(false)
                }
            }
        }
        // .overlay 空目录/加载中提示
        .overlay {
            if nav.isLoading && nav.entries.isEmpty {
                // 加载中：显示小型进度指示器
                ProgressView()
                    // .scaleEffect(0.8) 缩小到 80%
                    .scaleEffect(0.8)
            } else if nav.entries.isEmpty {
                // 空目录：显示灰色提示文字
                Text("空目录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // .onPreferenceChange 收集每行的 frame（用于框选碰撞检测）
        .onPreferenceChange(FileRowFrameKey.self) {
            if local { localFileRowFrames = $0 } else { remoteFileRowFrames = $0 }
        }
        #if os(macOS)
        // macOS: 拖拽框选手势（simultaneousGesture 不阻塞行的点击手势）
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("filePaneSpace"))
                .onChanged { value in
                    if local {
                        // 首次开始拖拽：记录基线选中集合，进入多选模式
                        if localDragRect == nil {
                            localDragBaseSelection = session.selectedLocalSet
                            session.isLocalMultiSelect = true
                        }
                        // 更新拖拽矩形
                        localDragRect = CGRect(origin: value.startLocation, end: value.location)
                    } else {
                        if remoteDragRect == nil {
                            remoteDragBaseSelection = session.selectedRemoteSet
                            session.isRemoteMultiSelect = true
                        }
                        remoteDragRect = CGRect(origin: value.startLocation, end: value.location)
                    }
                    // 根据拖拽矩形更新选中集合
                    updateSelectionFromDrag(local: local, entries: nav.entries)
                }
                .onEnded { _ in
                    // 拖拽结束：清除拖拽矩形和基线选中
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
        // .coordinateSpace 命名坐标空间，供 DragGesture 和 GeometryReader 使用
        .coordinateSpace(name: "filePaneSpace")
    }

    /// 行高亮背景:选中时填充系统高亮或强调色,未选中时透明。
    private func rowBackground(isSelected: Bool) -> some View {
        isSelected
            // 选中：15% 不透明度的主题色（蓝色高亮）
            ? Color.accentColor.opacity(0.15)
            // 未选中：透明
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
            // Shift+单击：范围选择
            let anchor = local ? session.localAnchor : session.remoteAnchor
            if isCommandKeyPressed {
                // ⌘+Shift+单击：将范围追加到当前选中集合
                if let anchor = anchor {
                    local
                        ? session.appendLocalRange(from: anchor, to: entry.name)
                        : session.appendRemoteRange(from: anchor, to: entry.name)
                } else {
                    // 无 anchor 时回退为追加单选
                    local
                        ? session.selectLocal(entry.name, append: true)
                        : session.selectRemote(entry.name, append: true)
                }
            } else {
                // Shift+单击（无 ⌘）：替换选中为范围
                if let anchor = anchor {
                    local
                        ? session.selectLocalRange(from: anchor, to: entry.name)
                        : session.selectRemoteRange(from: anchor, to: entry.name)
                } else {
                    // 无 anchor 时回退为单选并设立 anchor
                    local
                        ? session.selectLocal(entry.name, append: false)
                        : session.selectRemote(entry.name, append: false)
                }
            }
            return
        }
        // 无 Shift 键：普通单击
        // 多选模式或按 ⌘ 时追加选中，否则单选
        let append = multiSelect || isCommandKeyPressed
        if local {
            session.selectLocal(entry.name, append: append)
        } else {
            session.selectRemote(entry.name, append: append)
        }
    }

    /// 文件行:复选框(多选模式)+ 图标 + 名称 + 大小 + 修改时间。
    private func fileRow(entry: FileEntry, local: Bool, multiSelect: Bool, isSelected: Bool) -> some View {
        // HStack 水平排列行元素，间距 6pt
        HStack(spacing: 6) {
            // 多选模式时显示复选框
            if multiSelect {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    // 选中时主题色，未选中时灰色
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
            }
            // 文件/文件夹图标
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                // 文件夹蓝色，文件灰色
                .foregroundStyle(entry.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 20)
            // 文件/文件夹名称
            Text(entry.name)
                // .lineLimit(1) 单行显示，超长截断
                .lineLimit(1)
            // Spacer 将后面的元素推到右侧
            Spacer(minLength: 4)
            // 文件大小：文件夹显示 "—"，文件显示格式化大小
            Text(entry.isDirectory ? "—" : formatBytes(entry.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                // .frame(width: 70, alignment: .trailing) 固定宽度 70pt，右对齐
                .frame(width: 70, alignment: .trailing)
            // 修改时间：仅在非紧凑布局时显示
            if horizontalSizeClass != .compact {
                Text(entry.modified)
                    // .font(.system(.caption, design: .monospaced)) 等宽字体 caption 字号
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // .frame(width: 120, alignment: .trailing) 固定宽度 120pt，右对齐
                    .frame(width: 120, alignment: .trailing)
            }
        }
        // .font(.callout) 默认字号为 callout
        .font(.callout)
        // .contentShape(Rectangle()) 让整行都是可点击区域
        .contentShape(Rectangle())
        // .onTapGesture 单击选中
        .onTapGesture {
            handleRowTap(entry: entry, local: local, multiSelect: multiSelect)
        }
        // .simultaneousGesture 双击手势：目录进入、文件触发传输
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                Task {
                    local ? await session.doubleClickLocal(entry: entry) : await session.doubleClickRemote(entry: entry)
                }
            }
        )
        // .contextMenu 右键菜单（macOS 右键 / iPadOS 长按）
        .contextMenu { fileContextMenu(entry: entry, local: local, multiSelect: multiSelect) }
    }

    /// 评估连接门控：检查是否需要 TOFU 确认、密码输入等前置条件
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
        // collective: 是否对整个选中集合执行操作
        let collective = multiSelect && selectedSet.contains(entry.name) && count > 1
        // actionLabel: 生成操作标签（如「上传 3 项」）
        let actionLabel = { (verb: String) -> String in collective ? "\(verb) \(count) 项" : verb }
        // 目录类型：显示「进入」菜单项
        if entry.isDirectory {
            Button {
                Task {
                    local ? await session.enterLocal(entry.name) : await session.enterRemote(entry.name)
                }
            } label: {
                Label("进入", systemImage: "arrow.forward")
            }
        }
        // 本地面板：显示「上传」菜单项
        if local {
            Button {
                Task { await session.contextUpload(entry: entry) }
            } label: {
                Label(actionLabel("上传"), systemImage: "arrow.up")
            }
        } else {
            // 远程面板：显示「下载」菜单项
            Button {
                Task { await session.contextDownload(entry: entry) }
            } label: {
                Label(actionLabel("下载"), systemImage: "arrow.down")
            }
        }
        // 「删除」菜单项：destructive 角色（红色高亮）
        Button(role: .destructive) {
            // 多选右键选中集合内条目 → 删除整个集合;否则仅删除右键条目
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
                // 多选模式：显示选中数量 + 批量上传/下载按钮
                Text("已选 \(count) 项")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(local ? "上传 →" : "← 下载") {
                    Task {
                        let tasks = local ? await session.uploadSelected() : await session.downloadSelected()
                        if let first = tasks {
                            toast.show("已加入批量\(local ? "上传" : "下载")队列：\(first.name) 等 \(count) 项")
                            local ? session.toggleLocalMultiSelect() : session.toggleRemoteMultiSelect()
                        }
                    }
                }
                // .buttonStyle(.bordered) 带边框的按钮样式
                .buttonStyle(.bordered)
                // .controlSize(.small) 小号控件尺寸
                .controlSize(.small)
                // 没有选中任何项时禁用按钮
                .disabled(count == 0)
            } else if let selection = selectedSet.first {
                // 单选模式：显示选中项名称 + 上传/下载按钮
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
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                // 未选中：显示操作提示
                Text(local ? "单击选中 · 双击文件夹进入" : "单击选中 · 双击文件夹进入")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        // .font(.caption) caption 字号
        .font(.caption)
        // .padding(.horizontal, 10) 左右留 10pt 内边距
        .padding(.horizontal, 10)
        // .frame(minHeight:) 最小高度取 36 和 minimumInteractiveLength 的较大值
        .frame(minHeight: max(36, minimumInteractiveLength))
    }

    // MARK: - 真实连接

    /// 启动真实 SFTP 连接
    private func startRealConnection() async {
        // 记录当前尝试序号（用于检测重试冲突）
        let generation = attempt
        // 获取主机配置记录
        guard model.configRecord(for: host.id) != nil else {
            phase = .failed
            return
        }
        // 检查是否需要请求凭据输入
        if gate.requestCredentialsIfNeeded(for: host) { return }
        // 解析连接凭据
        let secrets = CredentialResolver()
            .connectionSecrets(for: host, manualSecret: gate.manualSecret)
        guard let secrets else {
            _ = gate.requestCredentialsIfNeeded(for: host)
            return
        }
        // 启动 SFTP 连接
        let error = await session.connect(password: secrets.password, passphrase: secrets.passphrase)
        // 检查任务是否已取消、尝试序号是否匹配、标签是否仍存在
        guard !Task.isCancelled, generation == attempt,
              workspace.tabs.contains(where: { $0.id == tab.id }) else { return }
        if let error {
            // 连接出错：分类错误并处理
            let classified = ConnectionFailure(error: error)
            if classified == .missingCredential {
                // 缺少凭据：要求用户输入
                gate.requireCredentialInput()
            } else if let key = classified.presentedHostKey,
                      gate.requireTofuConfirmation(key) {
                // 首次连接未知主机：缓存密钥，重新连接
                model.backend.cachePresentedKey(key, for: host.id)
                attempt += 1
                phase = .connecting
            } else {
                // 其他错误：显示失败
                failure = classified
                phase = .failed
            }
            return
        }
        // 连接成功：加载本地和远程目录
        let localOK = await session.localPane.reload()
        let remoteOK = await session.remotePane.reload()
        // 等待 300ms（让 UI 有时间更新）
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, generation == attempt else { return }
        if localOK && remoteOK {
            // 两边都加载成功：进入已连接状态
            phase = .connected
        } else {
            // 加载失败：显示错误
            failure = session.remotePane.lastError.map(ConnectionFailure.init(error:)) ?? .other("无法读取远程目录。")
            if failure == .missingCredential {
                gate.requireCredentialInput()
            } else {
                phase = .failed
            }
        }
    }

    // MARK: - 框选多选(每栏独立状态)

    /// 本地栏拖拽框选矩形（nil 表示没有拖拽进行中）
    @State private var localDragRect: CGRect? = nil
    /// 远程栏拖拽框选矩形
    @State private var remoteDragRect: CGRect? = nil
    /// 本地栏各行边界框,由 PreferenceKey 收集
    @State private var localFileRowFrames: [String: CGRect] = [:]
    /// 远程栏各行边界框,由 PreferenceKey 收集
    @State private var remoteFileRowFrames: [String: CGRect] = [:]
    /// 本地栏拖拽开始时的基线选中集合(用于 ⌘ 键追加模式)
    @State private var localDragBaseSelection: Set<String> = []
    /// 远程栏拖拽开始时的基线选中集合(用于 ⌘ 键追加模式)
    @State private var remoteDragBaseSelection: Set<String> = []

    /// 根据当前拖拽框与条目框架更新选中集合。
    /// 不按 ⌘ 时:选中集合 = 框内条目(覆盖基线)。
    /// 按 ⌘ 时:选中集合 = 基线 ∪ 框内条目(基线条目保留,框内条目追加)。
    private func updateSelectionFromDrag(local: Bool, entries: [FileEntry]) {
        let rect = local ? localDragRect : remoteDragRect
        guard let rect else { return }
        let frames = local ? localFileRowFrames : remoteFileRowFrames
        let baseSelection = local ? localDragBaseSelection : remoteDragBaseSelection
        // 是否按 ⌘ 键（追加模式）
        let isAppend = isCommandKeyPressed
        // 计算框内的条目名称集合
        let inRectNames = Set(entries.compactMap { entry -> String? in
            guard let frame = frames[entry.name] else { return nil }
            // rect.intersects(frame) 判断拖拽矩形是否与行 frame 相交
            return rect.intersects(frame) ? entry.name : nil
        })
        // 按 ⌘ 时取并集，否则直接替换
        let finalSelection = isAppend ? baseSelection.union(inRectNames) : inRectNames
        if local {
            session.selectedLocalSet = finalSelection
        } else {
            session.selectedRemoteSet = finalSelection
        }
    }

    /// 根据最终选中集合按列表顺序返回第一个被选中的条目名，作为范围选择 anchor。
    private func anchorFromSelection(entries: [FileEntry], selected: Set<String>) -> String? {
        entries.first { selected.contains($0.name) }?.name
    }
}

/// 收集每行在文件面板坐标系中的边界框,用于框选计算。
struct FileRowFrameKey: PreferenceKey {
    /// 默认值：空字典
    static var defaultValue: [String: CGRect] = [:]
    /// 合并函数：合并多个子视图上报的 frame，键冲突时保留新值
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 连续悬停时纠正从文本区域遗留的光标，不覆盖路径 TextField。
    /// macOS 专有：在悬停时强制设置箭头光标。iPadOS 上空操作。
    @ViewBuilder
    func sftpNavigationPointer() -> some View {
        #if os(macOS)
        // .onContinuousHover 监听持续悬停状态
        self.onContinuousHover { phase in
            if case .active = phase {
                // 鼠标在视图内时强制设置箭头光标
                NSCursor.arrow.set()
            }
        }
        #else
        // iPadOS: 空操作，直接返回 self
        self
        #endif
    }

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
    /// 用于拖拽框选：起点和终点可能任意顺序，此构造器自动规范化。
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
    /// 冲突信息（文件名、源/目标大小和日期）
    let conflict: PendingConflict
    /// 解决回调：true = 覆盖，false = 跳过
    let onResolve: (Bool) -> Void

    /// 环境 dismiss：用于关闭 sheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // VStack 垂直排列弹窗内容，间距 16pt
        VStack(spacing: 16) {
            // 标题：显示冲突文件名
            Text("\"\(conflict.name)\" 已存在")
                // .font(.headline) 标题字号
                .font(.headline)

            // HStack 并排展示源文件和目标文件信息
            HStack(alignment: .top, spacing: 24) {
                fileColumn(title: "源文件", size: conflict.sourceSize, date: conflict.sourceDate)
                // Divider 中间分隔线，固定高度 60pt
                Divider().frame(height: 60)
                fileColumn(title: "目标文件", size: conflict.targetSize, date: conflict.targetDate)
            }

            // HStack 底部操作按钮
            HStack(spacing: 16) {
                // 「跳过」按钮：不覆盖，取消角色
                Button("跳过", role: .cancel) {
                    onResolve(false)
                    dismiss()
                }

                // 「覆盖」按钮：覆盖文件，突出显示
                Button("覆盖") {
                    onResolve(true)
                    dismiss()
                }
                // .buttonStyle(.borderedProminent) 突出显示的带边框按钮（主题色背景）
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 文件信息列：标题 + 大小 + 日期
    private func fileColumn(title: String, size: UInt64, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 列标题（「源文件」或「目标文件」）
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            // 文件大小（格式化显示）
            Text(formatBytes(size))
                // .font(.system(.body, design: .rounded)) 圆体设计字号
                .font(.system(.body, design: .rounded))
            // 修改日期
            Text(date.map(formattedDate) ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // .frame(maxWidth: .infinity, alignment: .leading) 水平撑满，内容左对齐
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 格式化日期为本地化字符串（中等日期格式 + 短时间格式）
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        // 中等日期格式（如 "2024年1月15日"）
        formatter.dateStyle = .medium
        // 短时间格式（如 "下午3:30"）
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }
}

#if DEBUG
/// Xcode Preview: SFTP 双栏模式
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
    // .transferStore(transfers) 注入 TransferStore 环境对象
    .transferStore(transfers)
}
#endif
