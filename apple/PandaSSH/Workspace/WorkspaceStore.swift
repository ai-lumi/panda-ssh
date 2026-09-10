import Foundation
import Combine

/// 工作区标签页:一个标签页 = 一台主机上的一个会话(终端或 SFTP)。
/// `title` 由 Rust 侧工作区管理器统一重算(同主机序号消歧)。
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

/// 标签页工作区状态:持有标签数组与活动标签,负责打开/切换/关闭。
/// 标签列表、标题消歧、活动标签选择与连接状态跟踪均由 Rust 侧工作区
/// 管理器管理;Swift 侧通过 FFI 调用委托并同步 `@Published` 属性。
///
/// 关闭确认决策仍保留在 Swift 侧(通过 `terminalConnectedChecker` 注入点),
/// 便于测试隔离;实际标签移除由 Rust 执行。
///
/// 每个标签精确拥有连接；后台传输独立运行，不参与标签连接释放。
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var activeTabID: UUID?
    /// 待二次确认关闭的终端标签页 id;nil 表示无待确认关闭。
    @Published private(set) var pendingCloseTabID: UUID?
    /// 批量关闭时待确认的终端标签页集合(含目标范围与已连接数);nil 表示无待确认。
    @Published private(set) var pendingBatchClose: PendingBatchClose?

    /// 按 hostID 查询主机显示名;查不到(如主机已删除)时返回 nil,标题回退为 hostID。
    /// 同时用于在标签操作前同步主机名映射到 Rust。
    private let hostNameProvider: (String) -> String?
    /// 标签释放通知注入点，只传递正在关闭的标签，不执行主机级断开。
    private let closeSessionHandler: (WorkspaceTab) -> Void
    /// 判断指定终端标签页是否处于「已连接」状态(.shell),用于关闭二次确认门控。
    /// 测试可注入以隔离;生产环境由 `reportConnectionStatus` 维护 Rust 侧状态。
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
        self.hostNameProvider = hostNameProvider
        self.closeSessionHandler = closeSessionHandler
        self.transferStore = transferStore
        self.terminalConnectedChecker = terminalConnectedChecker ?? { _ in false }
        self.reconnectHandler = reconnectHandler ?? { [weak self] id in
            self?.terminalSessions[id]?.value?.retry()
        }
    }

    // MARK: - 主机名同步

    /// 将当前主机名映射同步到 Rust,确保标签标题消歧使用正确名称。
    /// 在打开标签页前调用,由 `AppModel.reload()` 触发增量更新。
    func syncHostNames(_ hostIDs: [String]) {
        let mappings = hostIDs.compactMap { id -> HostNameMapping? in
            guard let name = hostNameProvider(id) else { return nil }
            return HostNameMapping(hostId: id, name: name)
        }
        workspaceSetHostNames(hostNames: mappings)
    }

    // MARK: - 会话注册

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

    // MARK: - 连接状态

    /// 标记终端标签已连接(phase→.shell)。同时通知 Rust 侧工作区管理器,
    /// 用于关闭确认判断。
    func markTerminalConnected(tabID: UUID) {
        reportConnectionStatus(.connected, forTabID: tabID)
    }

    /// 标记终端标签已断开(phase→.failed 或连接丢失)。
    func markTerminalDisconnected(tabID: UUID) {
        reportConnectionStatus(.failed, forTabID: tabID)
    }

    /// 由终端/SFTP 页签在连接状态变化时调用。已被关闭的页签不得重新写入状态，
    /// 以避免 SwiftUI 的延迟 onDisappear 产生"幽灵连接"。
    /// 同时转发到 Rust 侧工作区管理器,维护关闭确认所需的连接状态。
    func reportConnectionStatus(_ status: WorkspaceConnectionStatus, forTabID tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        let ffiStatus: ConnectionStatusEnum
        switch status {
        case .inactive: ffiStatus = .inactive
        case .connecting: ffiStatus = .connecting
        case .connected: ffiStatus = .connected
        case .failed: ffiStatus = .failed
        }
        workspaceReportConnectionStatus(tabId: tabID.uuidString, status: ffiStatus)
    }

    /// 终端读循环确认远端 shell 已结束后调用。结束的标签仍保留在工作区，
    /// 连接已由会话自己释放，工作区只同步显示状态。
    func handleTerminalSessionEnded(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), tab.kind == .terminal else { return }
        reportConnectionStatus(.failed, forTabID: tabID)
    }

    /// 返回单个标签页的状态；从 Rust 侧标签记录读取。
    /// 不存在或已关闭时为 inactive。
    func connectionStatus(forTabID tabID: UUID) -> WorkspaceConnectionStatus {
        let records = workspaceTabList()
        guard let record = records.first(where: { $0.id == tabID.uuidString }) else { return .inactive }
        return connectionStatusFromFFI(record.connectionStatus)
    }

    /// 聚合同一主机全部已打开标签页的最近连接状态。
    /// 委托 Rust 侧 `workspaceHostConnectionStatus` 实现优先级聚合。
    func connectionStatus(forHostID hostID: String) -> WorkspaceConnectionStatus {
        let ffiStatus = workspaceHostConnectionStatus(hostId: hostID)
        return connectionStatusFromFFI(ffiStatus)
    }

    // MARK: - 标签页操作

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
        workspaceSelectTab(tabId: tabID.uuidString)
        syncFromFfi()
    }

    /// 关闭标签页;标签不存在时忽略。
    /// `force` 为 true 时先向 Rust 上报断开状态,绕过关闭确认(用于批量确认
    /// 后执行、主机删除级联等场景)。关闭活动标签后,活动标签优先落在
    /// 左侧相邻标签。
    func close(tabID: UUID, force: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        // 清理本地会话
        terminalSessions[tabID]?.value?.close()
        sftpSessions.removeValue(forKey: tabID)?.value?.disconnect()
        closeSessionHandler(tab)
        terminalSessions.removeValue(forKey: tabID)
        // force 模式下先向 Rust 报告断开,确保 Rust 侧 request_close 不设置 pending
        if force {
            workspaceReportConnectionStatus(tabId: tabID.uuidString, status: .inactive)
        }
        workspaceCloseTab(tabId: tabID.uuidString)
        syncFromFfi()
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
        close(tabID: id, force: true)
    }

    /// 取消关闭,保留待确认的终端标签页与会话。
    func cancelClose() {
        pendingCloseTabID = nil
    }

    /// 关闭除目标外的全部标签页;目标保留为活动标签。
    /// 被关闭的终端标签页走与单标签关闭一致的连接释放流程。
    func closeOthers(keeping tabID: UUID) {
        let others = tabs.filter { $0.id != tabID }.map(\.id)
        for id in others { close(tabID: id, force: true) }
        if tabs.contains(where: { $0.id == tabID }) {
            activeTabID = tabID
        }
    }

    /// 关闭全部标签页。
    func closeAll() {
        let ids = tabs.map(\.id)
        for id in ids { close(tabID: id, force: true) }
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

    /// 关闭某台主机的全部标签页(删除主机时级联清理)。
    /// 主机已被删除,其活跃传输任务无意义,先取消再立即断开连接。
    func closeTabs(forHostID hostID: String) {
        transferStore?.cancelAll(forHostID: hostID)
        let removedIDs = tabs.filter { $0.hostID == hostID }.map(\.id)
        for id in removedIDs {
            close(tabID: id, force: true)
        }
    }

    // MARK: - 内部

    private func open(hostID: String, kind: WorkspaceTab.Kind) -> UUID {
        // 确保 Rust 侧有该主机的名称,用于标题消歧
        if let name = hostNameProvider(hostID) {
            workspaceSetHostNames(hostNames: [HostNameMapping(hostId: hostID, name: name)])
        }
        let ffiKind: TabKindEnum = kind == .terminal ? .terminal : .sftp
        let record = workspaceOpenTab(hostId: hostID, kind: ffiKind)
        syncFromFfi()
        return UUID(uuidString: record.id) ?? UUID()
    }

    /// 从 Rust FFI 同步标签列表、活动标签与待关闭状态到 @Published 属性。
    private func syncFromFfi() {
        let records = workspaceTabList()
        tabs = records.compactMap { record in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return WorkspaceTab(
                id: id,
                hostID: record.hostId,
                kind: record.kind == .terminal ? .terminal : .sftp,
                title: record.title
            )
        }
        if let activeStr = workspaceActiveTabId() {
            activeTabID = UUID(uuidString: activeStr)
        } else {
            activeTabID = nil
        }
        // 同步 Rust 侧待关闭状态(Swift 侧设置的 pendingCloseTabID/pendingBatchClose 优先)
        syncPendingCloseFromRust()
    }

    /// 从 Rust 读取待关闭状态并更新 Swift 侧 @Published 属性。
    /// 仅在 Swift 侧未自行设置 pending 状态时从 Rust 读取。
    private func syncPendingCloseFromRust() {
        guard let pending = workspacePendingClose() else {
            // Rust 无 pending: 如果 Swift 侧也没有 pending, 无需操作
            // 如果 Swift 侧有 pending (由 requestClose/requestCloseOthers/requestCloseAll 设置), 保留
            return
        }
        let pendingIDs = Set(pending.tabIds.compactMap { UUID(uuidString: $0) })
        let count = Int(pending.connectedTerminalCount)

        // 如果 Swift 侧已设置了 pending 状态, 保留 Swift 侧的(它有 scope 信息)
        if pendingCloseTabID != nil || pendingBatchClose != nil { return }

        // 从 Rust pending 推断 scope
        if pendingIDs.count == 1, let id = pendingIDs.first {
            pendingCloseTabID = id
        } else if !pendingIDs.isEmpty {
            // 推断 scope: 如果只有一个标签不在 pending 中, 是 closeOthers
            let allTabIDs = Set(tabs.map(\.id))
            let nonPending = allTabIDs.subtracting(pendingIDs)
            if nonPending.count == 1, let keeping = nonPending.first {
                pendingBatchClose = PendingBatchClose(scope: .others(keeping: keeping), connectedTerminalCount: count)
            } else {
                pendingBatchClose = PendingBatchClose(scope: .all, connectedTerminalCount: count)
            }
        }
    }

    /// 将 FFI 连接状态枚举转换为 Swift 侧枚举。
    private func connectionStatusFromFFI(_ ffiStatus: ConnectionStatusEnum) -> WorkspaceConnectionStatus {
        switch ffiStatus {
        case .inactive: return .inactive
        case .connecting: return .connecting
        case .connected: return .connected
        case .failed: return .failed
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
