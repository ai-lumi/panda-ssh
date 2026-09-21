import SwiftUI

@main
struct PandaSSHApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PandaSSHApplicationDelegate.self) private var applicationDelegate
    #endif
    @StateObject private var model: AppModel
    @StateObject private var workspace: WorkspaceStore
    /// 全局传输任务队列(与原型全局传输列表一致,各 SFTP 标签共享)。
    /// 普通常量持有而非 `@StateObject`:App body 不订阅其 5Hz 状态发布,
    /// 避免传输期间整个主窗口树随任务进度重渲染;生命周期仍与 App 一致。
    private let transfers: TransferStore

    init() {
        // 先建 AppModel 与 TransferStore,再把主机名查询闭包与传输队列注入工作区
        // store,保证标签标题消歧时能拿到最新主机名，
        // 且三者与 App 同生命周期。
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let transfers = TransferStore()
        self.transfers = transfers
        let workspace = WorkspaceStore(
            hostNameProvider: { hostID in
                model.hosts.first(where: { $0.id == hostID })?.name
            },
            transferStore: transfers
        )
        _workspace = StateObject(wrappedValue: workspace)
        #if os(macOS)
        ApplicationQuitCoordinator.shared.installHandler {
            let protection = ApplicationQuitCoordinator.shared.quitProtection
            if protection.beginShutdownIfConfirmed() {
                workspace.beginApplicationShutdown()
                return true
            }
            return false
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(model)
                .environmentObject(workspace)
                .transferStore(transfers)
                .environmentObject(Logger.shared)
        }
        #if os(macOS)
        // 场景必须与自绘顶栏采用一致样式，否则 SwiftUI 在焦点或内容更新后
        // 会恢复不透明的系统标题栏，遮住伸入标题栏区域的按钮和页签。
        .windowStyle(.hiddenTitleBar)
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(workspace)
                .environmentObject(ToastCenter())
        }
        WindowGroup("日志", id: "panda-log") {
            LogView(logger: Logger.shared)
        }
        WindowGroup(ConnectionMonitorWindow.title, id: ConnectionMonitorWindow.id) {
            ConnectionMonitorView()
        }
        .defaultSize(width: 920, height: 680)
        Window(TransferWindow.title, id: TransferWindow.id) {
            TransferPageView(store: transfers)
                .environmentObject(model)
        }
        .defaultSize(width: 1000, height: 680)
        #endif
    }
}

enum TransferWindow {
    static let title = "传输任务"
    static let id = "panda-transfers"
}

enum ConnectionMonitorWindow {
    static let title = "连接监控"
    static let id = "panda-connection-monitor"
}

/// 全局开关:DEBUG 构建默认走真实后端,只有 Preview 与单元测试显式使用 Mock。
enum AppConfig {
    static var useMockBackend: Bool = false
}

/// 侧栏底部入口决定主区页面:主机(工作区)/代码片段/设置。
enum SidebarPage: Equatable {
    case hosts
    case connectionMonitor
    case transfers
    case snippets
    case settings
    case logs
}

/// 连接前检查的结果(阶段二在打开终端/SFTP 前据此弹对话框)。
enum PreconnectAction: Equatable {
    // 直接连接
    case proceed
    // 未知主机 → TOFU 指纹确认
    case confirmTofu
    // 主机密钥变更 → 红色告警并阻断
    case keyMismatch
    // 未存密码 → 手动输入(仅本次标签页会话)
    case askPassword
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [HostEntry] = []
    @Published private(set) var groups: [HostGroup] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published var lastError: String?
    /// 侧栏当前选中的主机;新建标签页入口据此工作。
    @Published var selectedHostID: String?
    /// 主内容区实际呈现对象。查看主机详情不会关闭或切换后台会话。
    @Published var workspacePresentation: WorkspacePresentationSelection = .empty
    /// 侧栏当前选中的分组;与主机选中互斥(单一选中语义)。
    @Published var selectedGroupID: String?
    /// 主区页面分支(侧栏底部入口切换)。
    @Published var sidebarPage: SidebarPage = .hosts
    /// 侧栏弹层(添加主机/新建分组等)的统一状态。
    /// 提升到模型层:入口按钮(macOS 在侧栏列顶部工具栏)与右键菜单共用,
    /// sheet 统一挂在根视图(HostListView)。
    @Published var sidebarSheet: SidebarSheetKind?
    /// 侧栏显隐控制(与 NavigationSplitView 绑定)。
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    let backend: any AppBackend

    var usesMockBackend: Bool { backend is MockBackend }

    init(backend: any AppBackend) {
        self.backend = backend
        lastError = backend.startupError
        reload()
    }

    convenience init() {
        if AppConfig.useMockBackend {
            self.init(backend: MockBackend.demo())
        } else {
            self.init(backend: PandaCoreBackend())
        }
    }

    func reload() {
        hosts = backend.allHosts()
        groups = backend.allGroups()
        snippets = backend.allSnippets()
        lastError = backend.startupError
        Logger.shared.info("配置加载完成; 主机数=\(hosts.count)", module: LogModule.config)
        // 同步主机名到 Rust 工作区,确保标签标题消歧使用最新名称
        let mappings = hosts.map { HostNameMapping(hostId: $0.id, name: $0.name) }
        workspaceSetHostNames(hostNames: mappings)
    }

    // MARK: 选中与页面切换

    /// 选中主机并切回主机页(选中片段/设置入口后再点主机时回到工作区)。
    func selectHost(_ id: String) {
        // 延迟到下一个 runloop:调用方可能是 List selection Binding 的 setter,
        // 在视图更新期间修改 @Published 会触发 "Publishing changes from within view updates" 警告。
        DispatchQueue.main.async {
            self.selectedHostID = id
            self.selectedGroupID = nil
            self.sidebarPage = .hosts
            self.workspacePresentation = .hostDetail(hostID: id)
        }
    }

    /// 选中分组并切回主机页。展开/折叠由 OutlineGroup 内部管理,不在模型层。
    func selectGroup(_ id: String) {
        DispatchQueue.main.async {
            self.selectedGroupID = id
            self.selectedHostID = nil
            self.sidebarPage = .hosts
            self.workspacePresentation = .empty
        }
    }

    /// 显示指定页签。页签有效性由 WorkspaceView 按 WorkspaceStore 归一化。
    func presentTab(_ id: UUID) {
        DispatchQueue.main.async {
            self.workspacePresentation = .tab(tabID: id)
            self.sidebarPage = .hosts
        }
    }

    /// 新建主机的默认归属分组:优先取当前选中的分组,
    /// 其次取选中主机所在的分组,都没有则归根级(nil)。
    var groupIDForNewHost: String? {
        if let selectedGroupID { return selectedGroupID }
        guard let selectedHostID else { return nil }
        return hosts.first(where: { $0.id == selectedHostID })?.groupID ?? nil
    }

    func showTransfers() {
        #if os(iOS)
        sidebarPage = .transfers
        #endif
    }

    func showSnippets() { sidebarPage = .snippets }
    func showConnectionMonitor() {
        #if os(iOS)
        sidebarPage = .connectionMonitor
        #endif
    }
    func showSettings() {
        #if os(iOS)
        isPresentingSettings = true
        #else
        sidebarPage = .settings
        #endif
    }
    func showLogs() { sidebarPage = .logs }

    /// iPad 全屏设置呈现状态。
    @Published var isPresentingSettings = false

    // MARK: 主机

    @discardableResult
    func saveHost(_ host: HostEntry, password: String?, passphrase: String?) -> Bool {
        guard backend.saveHost(host, password: password, passphrase: passphrase) else {
            lastError = backend.startupError
            return false
        }
        reload()
        return true
    }

    func deleteHost(id: String) {
        backend.deleteHost(id: id)
        if selectedHostID == id { selectedHostID = nil }
        if workspacePresentation == .hostDetail(hostID: id) {
            workspacePresentation = .empty
        }
        reload()
    }

    func moveHost(_ id: String, toGroup groupID: String?) {
        backend.moveHost(id: id, toGroup: groupID)
        reload()
    }

    /// TOFU 信任:记录对方出示的指纹,之后连接不再询问。
    func trustHost(id: String) {
        backend.trustHost(id: id)
        reload()
    }

    func presentedFingerprint(for hostID: String) -> String? {
        backend.presentedFingerprint(for: hostID)
    }

    func deleteCredentials(for hostID: String, auth: AuthKind) {
        backend.clearCredentials(for: hostID, auth: auth)
        reload()
    }

    /// 阶段二接线用:终端/SFTP 视图仍基于 HostConfigRecord。
    func configRecord(for hostID: String) -> HostConfigRecord? {
        backend.configRecord(for: hostID)
    }

    // MARK: - TOFU 确认并发串行化

    /// hostID → 等待该主机确认结果的续体列表。首个请求对应 nil,由它负责弹框;
    /// 后续请求挂入列表,在首个确认结束后收到广播结果。
    private var pendingTofu: [String: [CheckedContinuation<Bool, Never>]] = [:]

    /// 请求加入某主机的 TOFU 确认队列。
    /// - 返回 `nil`:调用者是首个确认者,应弹出确认框。
    /// - 返回 `Bool`:已有确认完成(或正在等待),返回最终用户选择(true=信任)。
    func awaitTofuConfirmation(for hostID: String) async -> Bool? {
        if pendingTofu[hostID] == nil {
            pendingTofu[hostID] = []
            return nil
        }
        return await withCheckedContinuation { continuation in
            pendingTofu[hostID, default: []].append(continuation)
        }
    }

    /// 完成某主机的 TOFU 确认,广播结果给所有等待者,并清理队列。
    /// 调用方应在用户点击「信任」或「取消」时调用。
    func resolveTofuConfirmation(for hostID: String, trusted: Bool) {
        if trusted { trustHost(id: hostID) }
        let waiters = pendingTofu.removeValue(forKey: hostID) ?? []
        for continuation in waiters {
            continuation.resume(returning: trusted)
        }
    }

    /// 连接前检查(与原型 preConnect 一致):未知主机 → TOFU;
    /// 密钥不匹配 → 告警阻断;密码未存 → 逐标签页手动输入;否则直接连。
    nonisolated static func preconnectAction(for host: HostEntry) -> PreconnectAction {
        if host.fingerprint == nil && host.demo == .unknown { return .confirmTofu }
        if host.demo == .mismatch { return .keyMismatch }
        if host.demo == .manual { return .askPassword }
        return .proceed
    }

    // MARK: 分组

    @discardableResult
    func createGroup(name: String, parentID: String?) -> HostGroup {
        let group = backend.createGroup(name: name, parentID: parentID)
        reload()
        return group
    }

    func renameGroup(id: String, name: String) {
        backend.renameGroup(id: id, name: name)
        reload()
    }

    /// 删除分组:组内(含子分组)主机移回根级,子分组一并删除。
    func deleteGroup(id: String) {
        backend.deleteGroup(id: id)
        reload()
        // 选中的分组(或其某个祖先)被删除后清除选中态
        if let sid = selectedGroupID, !groups.contains(where: { $0.id == sid }) {
            selectedGroupID = nil
        }
    }

    // MARK: 代码片段

    @discardableResult
    func saveSnippet(_ snippet: Snippet) -> Snippet {
        backend.saveSnippet(snippet)
        reload()
        return snippet
    }

    func deleteSnippet(id: String) {
        backend.deleteSnippet(id: id)
        reload()
    }
}
