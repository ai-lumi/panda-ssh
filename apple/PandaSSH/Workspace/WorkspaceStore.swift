import Foundation
import Combine

/// 页签栏溢出后的显示策略。
enum TabBarOverflowMode: String, CaseIterable, Identifiable {
    case scroll
    case expand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: return "左右滚动（默认）"
        case .expand: return "多行显示"
        }
    }
}

/// 工作区标签页:一个标签页 = 一台主机上的一个会话(终端或 SFTP)。
/// `title` 由 `WorkspaceStore` 在标签数组变化时统一重算(同主机序号消歧)。
struct WorkspaceTab: Identifiable, Equatable {
    /// 标签页类型:终端或 SFTP 文件浏览器
    enum Kind: Equatable {
        case terminal
        case sftp
    }

    let id: UUID
    let hostID: String
    let kind: Kind
    var title: String
}

/// 标签页所掌握的当前连接状态。它只反映已打开会话的最近结果，
/// 不对未连接的主机发起后台网络探测。
enum WorkspaceConnectionStatus: Equatable {
    case inactive
    case connecting
    case connected
    case failed
}

/// 批量关闭待确认范围:关闭其他 / 关闭全部。
/// `connectedTerminalCount` 为范围内已连接终端标签数,用于聚合确认文案。
struct PendingBatchClose: Equatable {
    enum Scope: Equatable {
        case others(keeping: UUID)
        case all
    }
    let scope: Scope
    let connectedTerminalCount: Int
}

/// 标签页工作区状态:持有标签数组与活动标签,负责打开/切换/关闭
/// 以及同主机标签标题的序号消歧。主机名通过注入的查询闭包解析,
/// 便于测试替换、也避免模型层反向依赖 AppModel。
///
/// 每个标签精确拥有连接；后台传输独立运行，不参与标签连接释放。
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var activeTabID: UUID?
    /// 页签栏溢出模式：左右滚动或多行显示，从 UserDefaults 持久化。
    @Published var tabBarOverflowMode: TabBarOverflowMode = .scroll {
        didSet {
            UserDefaults.standard.set(tabBarOverflowMode.rawValue, forKey: "panda.tabBarOverflowMode")
        }
    }
    /// 待二次确认关闭的终端标签页 id;nil 表示无待确认关闭。
    @Published private(set) var pendingCloseTabID: UUID?
    /// 批量关闭时待确认的终端标签页集合(含目标范围与已连接数);nil 表示无待确认。
    @Published private(set) var pendingBatchClose: PendingBatchClose?
    /// 每个已打开标签页上报的当前连接状态。用 `@Published` 使页签栏与侧栏
    /// 能在读循环发现断开后立即重新渲染。
    @Published private var tabConnectionStatuses: [UUID: WorkspaceConnectionStatus] = [:]
    /// 已连接终端标签集合(tabID)。独立于视图生命周期:
    /// TerminalTabView 在 phase→.shell 时 markConnected,仅在标签关闭时清理。
    /// 解决:非活动终端标签(视图已销毁)仍需关闭确认的问题。
    private var connectedTerminalTabs: Set<UUID> = []

    /// 按 hostID 查询主机显示名;查不到(如主机已删除)时返回 nil,标题回退为 hostID。
    private let hostNameProvider: (String) -> String?
    /// 标签释放通知注入点，只传递正在关闭的标签，不执行主机级断开。
    private let closeSessionHandler: (WorkspaceTab) -> Void
    /// 判断指定终端标签页是否处于「已连接」状态(.shell),用于关闭二次确认门控。
    /// 默认走 `terminalSessions` 注册表;测试可注入以隔离。
    /// 注意:这里用 `var` 并给占位默认值,是因为默认闭包需要捕获 `self`,
    /// 而 `self` 在 init 中必须先完成两阶段初始化才能被捕获。
    private var terminalConnectedChecker: (UUID) -> Bool = { _ in false }
    /// 重连终端标签页时调用,参数为 tabID。默认走注册表转发到 TerminalSessionStore.retry。
    private var reconnectHandler: (UUID) -> Void = { _ in }
    /// 仅主机删除时级联取消任务；普通标签关闭不操作传输队列。
    private weak var transferStore: TransferStore?
    /// 终端标签页会话注册表:tabID -> 弱引用 TerminalSessionStore。
    /// 由 TerminalTabView 在 onAppear/onDisappear 维护,用于关闭确认与重连。
    private var terminalSessions: [UUID: WeakTerminalSession] = [:]
    private var sftpSessions: [UUID: WeakSftpSession] = [:]

    init(
        hostNameProvider: @escaping (String) -> String?,
        closeSessionHandler: @escaping (WorkspaceTab) -> Void = { _ in },
        transferStore: TransferStore? = nil,
        terminalConnectedChecker: ((UUID) -> Bool)? = nil,
        reconnectHandler: ((UUID) -> Void)? = nil
    ) {
        if let raw = UserDefaults.standard.string(forKey: "panda.tabBarOverflowMode"),
           let mode = TabBarOverflowMode(rawValue: raw) {
            self.tabBarOverflowMode = mode
        }
        self.hostNameProvider = hostNameProvider
        self.closeSessionHandler = closeSessionHandler
        self.transferStore = transferStore
        self.terminalConnectedChecker = terminalConnectedChecker ?? { [weak self] id in
            self?.connectedTerminalTabs.contains(id) ?? false
        }
        self.reconnectHandler = reconnectHandler ?? { [weak self] id in
            self?.terminalSessions[id]?.value?.retry()
        }
    }

    /// 注册终端会话(由 TerminalTabView.onAppear 调用)。
    func registerTerminal(_ session: TerminalSessionStore, for tabID: UUID) {
        terminalSessions[tabID] = WeakTerminalSession(value: session)
    }

    func registerSftp(_ session: SftpSessionStore, for tabID: UUID) {
        sftpSessions[tabID] = WeakSftpSession(value: session)
    }

    /// 注销终端会话。仅在标签实际关闭时调用(非视图切换)。
    func unregisterTerminal(for tabID: UUID) {
        terminalSessions.removeValue(forKey: tabID)
    }

    /// 标记终端标签已连接(phase→.shell)。独立于视图生命周期,
    /// 切换标签时视图销毁不会清除此标记,确保非活动终端仍可触发关闭确认。
    func markTerminalConnected(tabID: UUID) {
        connectedTerminalTabs.insert(tabID)
    }

    /// 标记终端标签已断开(phase→.failed 或连接丢失)。
    func markTerminalDisconnected(tabID: UUID) {
        connectedTerminalTabs.remove(tabID)
    }

    /// 由终端/SFTP 页签在连接状态变化时调用。已被关闭的页签不得重新写入状态，
    /// 以避免 SwiftUI 的延迟 onDisappear 产生“幽灵连接”。
    func reportConnectionStatus(_ status: WorkspaceConnectionStatus, forTabID tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        tabConnectionStatuses[tabID] = status
        if tabs.first(where: { $0.id == tabID })?.kind == .terminal {
            if status == .connected {
                markTerminalConnected(tabID: tabID)
            } else if status == .failed || status == .inactive {
                markTerminalDisconnected(tabID: tabID)
            }
        }
    }

    /// 终端读循环确认远端 shell 已结束后调用。结束的标签仍保留在工作区，
    /// 连接已由会话自己释放，工作区只同步显示状态。
    func handleTerminalSessionEnded(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), tab.kind == .terminal else { return }
        reportConnectionStatus(.failed, forTabID: tabID)
    }

    /// 返回单个标签页的状态；不存在或已关闭时为 inactive。
    func connectionStatus(forTabID tabID: UUID) -> WorkspaceConnectionStatus {
        tabConnectionStatuses[tabID] ?? .inactive
    }

    /// 聚合同一主机全部已打开标签页的最近连接状态。只要任一会话可用就为 connected；
    /// 这避免一个失败的并行标签把仍可交互的主机误标为不可达。
    func connectionStatus(forHostID hostID: String) -> WorkspaceConnectionStatus {
        let statuses = tabs.filter { $0.hostID == hostID }.map { connectionStatus(forTabID: $0.id) }
        if statuses.contains(.connected) { return .connected }
        if statuses.contains(.connecting) { return .connecting }
        if statuses.contains(.failed) { return .failed }
        return .inactive
    }

    /// 打开终端标签页。总是新建,不做按主机的去重。
    @discardableResult
    func openTerminal(hostID: String) -> UUID {
        open(hostID: hostID, kind: .terminal)
    }

    /// 打开 SFTP 标签页。总是新建,不做按主机的去重。
    @discardableResult
    func openSFTP(hostID: String) -> UUID {
        open(hostID: hostID, kind: .sftp)
    }

    /// 切换活动标签;标签不存在时忽略。
    func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    /// 关闭标签页;标签不存在时忽略。关闭活动标签后,活动标签优先落在
    /// 左侧相邻标签,越界(关闭的是第一个)则落在原索引位置,即原右侧邻居。
    /// 同步释放该标签，不依赖 SwiftUI 延迟的 onDisappear。
    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        terminalSessions[tabID]?.value?.close()
        sftpSessions.removeValue(forKey: tabID)?.value?.disconnect()
        closeSessionHandler(tab)
        connectedTerminalTabs.remove(tabID)
        terminalSessions.removeValue(forKey: tabID)
        tabConnectionStatuses.removeValue(forKey: tabID)
        let closingActive = (activeTabID == tabID)
        tabs.remove(at: index)
        if closingActive {
            activeTabID = tabs.isEmpty ? nil : tabs[max(index - 1, 0)].id
        }
        retitle()
    }

    /// 请求关闭标签页:已连接终端标签页弹出二次确认(设置 pendingCloseTabID);
    /// 连接中/失败态终端标签页与 SFTP 标签页直接关闭。
    func requestClose(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.kind == .terminal && terminalConnectedChecker(tabID) {
            pendingCloseTabID = tabID
        } else {
            close(tabID: tabID)
        }
    }

    /// 确认关闭待确认的终端标签页。
    func confirmClose() {
        guard let id = pendingCloseTabID else { return }
        pendingCloseTabID = nil
        close(tabID: id)
    }

    /// 取消关闭,保留待确认的终端标签页与会话。
    func cancelClose() {
        pendingCloseTabID = nil
    }

    /// 关闭除目标外的全部标签页;目标保留为活动标签。
    /// 被关闭的终端标签页走与单标签关闭一致的连接释放流程(直接断开,
    /// 不弹逐个确认;批量关闭的聚合确认由视图层在调用前处理)。
    func closeOthers(keeping tabID: UUID) {
        let others = tabs.filter { $0.id != tabID }.map(\.id)
        for id in others { close(tabID: id) }
        if tabs.contains(where: { $0.id == tabID }) {
            activeTabID = tabID
        }
    }

    /// 关闭全部标签页。
    func closeAll() {
        let ids = tabs.map(\.id)
        for id in ids { close(tabID: id) }
    }

    /// 重连终端标签页;SFTP 标签页为 no-op。
    func reconnectTerminal(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), tab.kind == .terminal else { return }
        reconnectHandler(tabID)
    }

    /// 请求「关闭其他标签页」:若范围内存在已连接终端标签 → 设置 pendingBatchClose
    /// 等待聚合确认;否则直接执行 closeOthers。
    func requestCloseOthers(keeping tabID: UUID) {
        let others = tabs.filter { $0.id != tabID }
        let connectedCount = others.filter { $0.kind == .terminal && terminalConnectedChecker($0.id) }.count
        if connectedCount > 0 {
            pendingBatchClose = PendingBatchClose(scope: .others(keeping: tabID), connectedTerminalCount: connectedCount)
        } else {
            closeOthers(keeping: tabID)
        }
    }

    /// 请求「关闭全部标签页」:若范围内存在已连接终端标签 → 设置 pendingBatchClose
    /// 等待聚合确认;否则直接执行 closeAll。
    func requestCloseAll() {
        let connectedCount = tabs.filter { $0.kind == .terminal && terminalConnectedChecker($0.id) }.count
        if connectedCount > 0 {
            pendingBatchClose = PendingBatchClose(scope: .all, connectedTerminalCount: connectedCount)
        } else {
            closeAll()
        }
    }

    /// 确认批量关闭:按 pending 范围执行 closeOthers/closeAll,并清理 pending。
    func confirmBatchClose() {
        guard let pending = pendingBatchClose else { return }
        pendingBatchClose = nil
        switch pending.scope {
        case .others(let keep):
            closeOthers(keeping: keep)
        case .all:
            closeAll()
        }
    }

    /// 取消批量关闭:清理 pending,保留全部标签页。
    func cancelBatchClose() {
        pendingBatchClose = nil
    }

    private func open(hostID: String, kind: WorkspaceTab.Kind) -> UUID {
        let tab = WorkspaceTab(id: UUID(), hostID: hostID, kind: kind, title: "")
        tabs.append(tab)
        tabConnectionStatuses[tab.id] = .connecting
        activeTabID = tab.id
        retitle()
        return tab.id
    }

    /// 关闭某台主机的全部标签页(删除主机时级联清理)。
    /// 主机已被删除,其活跃传输任务无意义,先取消再立即断开连接。
    func closeTabs(forHostID hostID: String) {
        transferStore?.cancelAll(forHostID: hostID)
        let removedIDs = tabs.filter { $0.hostID == hostID }.map(\.id)
        for id in removedIDs {
            close(tabID: id)
        }
    }

    /// 重算全部标签标题:同一主机的标签按数组中的稳定顺序编号,
    /// 第一个不带序号,后续为「名称 (2)」「名称 (3)」……
    private func retitle() {
        // 记录每个主机已出现的标签数,按数组顺序递增
        var counts: [String: Int] = [:]
        for index in tabs.indices {
            let hostID = tabs[index].hostID
            let base = hostNameProvider(hostID) ?? hostID
            let ordinal = (counts[hostID] ?? 0) + 1
            counts[hostID] = ordinal
            tabs[index].title = ordinal == 1 ? base : "\(base) (\(ordinal))"
        }
    }
}

/// TerminalSessionStore 的弱引用包装,用于注册表避免循环引用。
final class WeakTerminalSession {
    weak var value: TerminalSessionStore?
    init(value: TerminalSessionStore) { self.value = value }
}

final class WeakSftpSession {
    weak var value: SftpSessionStore?
    init(value: SftpSessionStore) { self.value = value }
}
