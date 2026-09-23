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
/// 关闭确认决策通过 `isTerminalConnected` 查询 Rust 侧连接状态实现,
/// 实际标签移除由 Rust 执行。
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
    /// 应用停机期间拒绝创建新标签，防止异步 UI 事件在关闭快照之后新建连接。
    @Published private(set) var isAcceptingNewConnections = true
    /// 页签分组列表，仅会话内保持，不持久化。
    @Published private(set) var groups: [TabGroup] = []
    /// 未分配到任何分组的页签 ID 列表，按显示顺序。
    @Published private(set) var ungroupedTabIDs: [UUID] = []
    /// 页签显示顺序映射，独立于 Rust 侧 tabs 数组。
    private var displayOrder: [UUID] = []

    /// 按 hostID 查询主机显示名;查不到(如主机已删除)时返回 nil,标题回退为 hostID。
    /// 同时用于在标签操作前同步主机名映射到 Rust。
    private let hostNameProvider: (String) -> String?
    /// 标签释放通知注入点，只传递正在关闭的标签，不执行主机级断开。
    private let closeSessionHandler: (WorkspaceTab) -> Void
    /// 判断指定终端标签页是否处于「已连接」状态(.shell),用于关闭二次确认门控。
    /// 直接查询 Rust 侧连接状态，无需外部注入。
    private func isTerminalConnected(_ tabID: UUID) -> Bool {
        connectionStatus(forTabID: tabID) == .connected
    }
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
        reconnectHandler: ((UUID) -> Void)? = nil
    ) {
        self.hostNameProvider = hostNameProvider
        self.closeSessionHandler = closeSessionHandler
        self.transferStore = transferStore
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

    // MARK: - 连接状态

    /// 由终端/SFTP 页签在连接状态变化时调用。已被关闭的页签不得重新写入状态，
    /// 以避免 SwiftUI 的延迟 onDisappear 产生"幽灵连接"。
    /// 同时转发到 Rust 侧工作区管理器,维护关闭确认所需的连接状态。
    func reportConnectionStatus(_ status: WorkspaceConnectionStatus, forTabID tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard connectionStatus(forTabID: tabID) != status else { return }
        let ffiStatus: ConnectionStatusEnum
        switch status {
        case .inactive: ffiStatus = .inactive
        case .connecting: ffiStatus = .connecting
        case .connected: ffiStatus = .connected
        case .failed: ffiStatus = .failed
        }
        // 状态由 Rust 持有，不经过 @Published；主动通知页签和侧栏在下一轮重绘时读取新值。
        objectWillChange.send()
        workspaceReportConnectionStatus(tabId: tabID.uuidString.lowercased(), status: ffiStatus)
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
        guard let record = records.first(where: { UUID(uuidString: $0.id) == tabID }) else { return .inactive }
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
        workspaceSelectTab(tabId: tabID.uuidString.lowercased())
        syncFromFfi()
    }

    /// 切换到下一个页签（从左往右循环，按显示顺序）。
    /// 无页签或无活动页签时忽略。
    func selectNextTab() {
        let displayed = displayedTabs
        guard let currentIndex = displayed.firstIndex(where: { $0.id == activeTabID }) else { return }
        guard let nextIndex = nextTabIndex(current: currentIndex, total: displayed.count) else { return }
        select(tabID: displayed[nextIndex].id)
    }

    /// 切换到上一个页签（从右往左循环，按显示顺序）。
    /// 无页签或无活动页签时忽略。
    func selectPreviousTab() {
        let displayed = displayedTabs
        guard let currentIndex = displayed.firstIndex(where: { $0.id == activeTabID }) else { return }
        guard let previousIndex = previousTabIndex(current: currentIndex, total: displayed.count) else { return }
        select(tabID: displayed[previousIndex].id)
    }

    /// 获取当前活动页签的索引。
    private func currentIndex() -> Int? {
        guard let activeTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == activeTabID })
    }

    /// 执行关闭;需要用户确认的入口先调用 requestClose。
    /// 先移除工作区页签,再释放该页签会话,避免延迟状态回调保留幽灵页签。
    /// 标签不存在时忽略;关闭活动标签后优先选择左侧相邻标签。
    func close(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let ffiTabID = tabID.uuidString.lowercased()
        if tab.kind == .terminal {
            reportConnectionStatus(.inactive, forTabID: tabID)
        }
        workspaceCloseTab(tabId: ffiTabID)
        syncAndReleaseSessions(previousTabIDs: Set([tabID]))
    }

    /// 请求关闭标签页:委托核心判断是否需要二次确认。
    /// 核心返回 .closed 时标签已移除;返回 .pendingConfirmation 时同步待确认状态。
    func requestClose(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        let before = Set(tabs.map(\.id))
        let result = workspaceCloseTab(tabId: tabID.uuidString.lowercased())
        if result == .closed {
            syncAndReleaseSessions(previousTabIDs: before)
        } else {
            syncFromFfi()
        }
    }

    /// 确认关闭待确认的标签页,转发到核心执行。
    func confirmClose() {
        let before = Set(tabs.map(\.id))
        workspaceConfirmClose()
        syncAndReleaseSessions(previousTabIDs: before)
    }

    /// 取消关闭,转发到核心清除待确认状态。
    func cancelClose() {
        workspaceCancelClose()
        syncFromFfi()
    }

    /// 关闭全部标签页。
    func requestCloseAll() {
        let before = Set(tabs.map(\.id))
        let result = workspaceCloseAllTabs()
        if result == .closed {
            syncAndReleaseSessions(previousTabIDs: before)
        } else {
            syncFromFfi()
        }
    }

    func requestCloseOthers(keeping tabID: UUID) {
        let before = Set(tabs.map(\.id))
        let result = workspaceCloseOtherTabs(keepingTabId: tabID.uuidString.lowercased())
        if result == .closed {
            syncAndReleaseSessions(previousTabIDs: before)
        } else {
            syncFromFfi()
        }
    }

    /// 页签操作的唯一重连入口；由各标签自己的会话状态机建立新连接代次。
    func reconnectSession(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        switch tab.kind {
        case .terminal:
            reconnectHandler(tabID)
        case .sftp:
            sftpSessions[tabID]?.value?.requestReconnect()
        }
    }

    func confirmBatchClose() {
        let before = Set(tabs.map(\.id))
        workspaceConfirmClose()
        syncAndReleaseSessions(previousTabIDs: before)
    }

    func cancelBatchClose() {
        workspaceCancelClose()
        syncFromFfi()
    }

    /// 关闭某台主机的全部标签页(删除主机时级联清理)。
    /// 主机已被删除,其活跃传输任务无意义,先取消再立即断开连接。
    /// 先报告终端为 inactive 以绕过确认,再由核心直接关闭。
    func closeTabs(forHostID hostID: String) {
        transferStore?.cancelAll(forHostID: hostID)
        let hostTerminalIDs = tabs.filter { $0.hostID == hostID && $0.kind == .terminal }.map(\.id)
        for id in hostTerminalIDs {
            reportConnectionStatus(.inactive, forTabID: id)
        }
        let removedIDs = tabs.filter { $0.hostID == hostID }.map(\.id)
        for id in removedIDs {
            close(tabID: id)
        }
    }

    /// 应用级停机：关闭新工作入口、取消传输、无确认关闭全部标签并请求释放全部连接。
    /// 重复调用为 no-op，确保第二次 CMD+Q 的重复事件不会二次释放同一资源。
    func beginApplicationShutdown() {
        guard isAcceptingNewConnections else { return }
        isAcceptingNewConnections = false
        transferStore?.beginApplicationShutdown()
        _ = workspaceBeginApplicationShutdown()
        syncFromFfi()
    }

    // MARK: - 页签排序与分组

    /// 按分组和排序顺序返回的页签列表，用于 UI 渲染。
    /// 顺序：按 groups 顺序输出每组页签，最后输出 ungroupedTabIDs。
    var displayedTabs: [WorkspaceTab] {
        var result: [WorkspaceTab] = []
        let tabDict = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        // 按分组顺序输出
        for group in groups {
            for tabID in group.tabIDs {
                if let tab = tabDict[tabID] {
                    result.append(tab)
                }
            }
        }

        // 输出未分组页签
        for tabID in ungroupedTabIDs {
            if let tab = tabDict[tabID] {
                result.append(tab)
            }
        }

        return result
    }

    /// 创建新分组并将指定页签分配进去。
    /// - Parameters:
    ///   - tabID: 要分配到新分组的页签 ID
    ///   - name: 分组名称，为 nil 时自动生成
    /// - Returns: 新创建的分组 ID
    func createGroup(forTabID tabID: UUID, name: String? = nil) -> UUID {
        let groupIDStr = workspaceCreateGroup(tabId: tabID.uuidString.lowercased(), name: name)
        syncGroupsFromFfi()
        return UUID(uuidString: groupIDStr) ?? UUID()
    }

    /// 删除指定分组。
    /// 若分组非空，组内页签移至未分组状态。
    func deleteGroup(id: UUID) {
        workspaceDeleteGroup(groupId: id.uuidString.lowercased())
        syncGroupsFromFfi()
    }

    /// 重命名指定分组。
    func renameGroup(id: UUID, to newName: String) {
        workspaceRenameGroup(groupId: id.uuidString.lowercased(), newName: newName)
        syncGroupsFromFfi()
    }

    /// 将页签移动到指定分组。
    /// 若页签已在其他分组，先从原分组移除。
    func moveTab(_ tabID: UUID, toGroup groupID: UUID) {
        workspaceMoveTabToGroup(tabId: tabID.uuidString.lowercased(), groupId: groupID.uuidString.lowercased())
        syncGroupsFromFfi()
    }

    /// 将页签从分组中移除，变为未分组状态。
    func removeTabFromGroup(_ tabID: UUID) {
        workspaceRemoveTabFromGroup(tabId: tabID.uuidString.lowercased())
        syncGroupsFromFfi()
    }

    // MARK: - 拖放事务

    /// 拖放开始时的快照，用于取消时恢复原始顺序。
    struct TabReorderSnapshot {
        let tabID: UUID
        let ungroupedTabIDs: [UUID]
        let groupStates: [(groupID: UUID, tabIDs: [UUID])]
    }

    /// 是否存在未提交或未回滚的拖放预览。
    var hasPendingTabReorder: Bool { activeReorderSnapshot != nil }

    /// 当前进行中的拖放快照；nil 表示无拖放。
    private var activeReorderSnapshot: TabReorderSnapshot?

    /// 开始拖放时捕获受影响容器的当前顺序快照。
    /// 返回的快照应在 `commitTabReorder` 或 `rollbackTabReorder` 中传回。
    func beginTabReorder(for tabID: UUID) -> TabReorderSnapshot {
        let snapshot = TabReorderSnapshot(
            tabID: tabID,
            ungroupedTabIDs: ungroupedTabIDs,
            groupStates: groups.map { ($0.id, $0.tabIDs) }
        )
        activeReorderSnapshot = snapshot
        return snapshot
    }

    /// 拖放过程中的临时预览：按实际渲染容器更新未分组或同组顺序。
    /// 跨组目标不提交排序（不在本变更范围内）。
    func previewTabMove(_ tabID: UUID, before targetTabID: UUID) {
        guard tabID != targetTabID else { return }

        if ungroupedTabIDs.contains(tabID), ungroupedTabIDs.contains(targetTabID) {
            moveTabInUngrouped(tabID, before: targetTabID)
        } else if let sourceGroupID = groupID(forTabID: tabID),
                  sourceGroupID == groupID(forTabID: targetTabID) {
            moveTabInGroup(tabID, before: targetTabID, groupID: sourceGroupID)
        }
        // 跨组目标不提交排序
    }

    /// 提交拖放结果：清除拖拽状态，保留当前顺序。
    func commitTabReorder(_ snapshot: TabReorderSnapshot) {
        activeReorderSnapshot = nil
        _ = snapshot
    }

    /// 提交当前未完成的拖放；没有活动会话时为 no-op。
    func commitPendingTabReorder() {
        guard let snapshot = activeReorderSnapshot else { return }
        commitTabReorder(snapshot)
    }

    /// 取消拖放：恢复到开始前的顺序，清除拖拽反馈。
    func rollbackTabReorder(_ snapshot: TabReorderSnapshot) {
        restoreTabReorder(snapshot)
        activeReorderSnapshot = nil
    }

    /// 取消当前未提交的拖放。视图层无需持有快照，即可在鼠标抬起、Escape
    /// 或拖放会话中断时恢复开始前顺序。
    func cancelPendingTabReorder() {
        guard let snapshot = activeReorderSnapshot else { return }
        restoreTabReorder(snapshot)
        activeReorderSnapshot = nil
    }

    private func restoreTabReorder(_ snapshot: TabReorderSnapshot) {
        guard tabs.contains(where: { $0.id == snapshot.tabID }) else { return }
        let validTabIDs = Set(tabs.map(\.id))
        ungroupedTabIDs = snapshot.ungroupedTabIDs.filter { validTabIDs.contains($0) }
        for saved in snapshot.groupStates {
            guard let idx = groups.firstIndex(where: { $0.id == saved.groupID }) else { continue }
            groups[idx].tabIDs = saved.tabIDs.filter { validTabIDs.contains($0) }
        }
    }

    /// 在 ungroupedTabIDs 中将 tabID 移动到 targetTabID 前。
    private func moveTabInUngrouped(_ tabID: UUID, before targetTabID: UUID) {
        guard let from = ungroupedTabIDs.firstIndex(of: tabID) else { return }
        guard let to = ungroupedTabIDs.firstIndex(of: targetTabID) else { return }
        ungroupedTabIDs.remove(at: from)
        let adjustedTo = to > from ? to - 1 : to
        ungroupedTabIDs.insert(tabID, at: adjustedTo)
    }

    /// 在指定分组的 tabIDs 中将 tabID 移动到 targetTabID 前。
    private func moveTabInGroup(_ tabID: UUID, before targetTabID: UUID, groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard let from = groups[idx].tabIDs.firstIndex(of: tabID) else { return }
        guard let to = groups[idx].tabIDs.firstIndex(of: targetTabID) else { return }
        groups[idx].tabIDs.remove(at: from)
        let adjustedTo = to > from ? to - 1 : to
        groups[idx].tabIDs.insert(tabID, at: adjustedTo)
    }

    /// 查询页签所在分组的 ID；未分组返回 nil。
    private func groupID(forTabID tabID: UUID) -> UUID? {
        groups.first(where: { $0.tabIDs.contains(tabID) })?.id
    }

    // MARK: - 内部

    private func open(hostID: String, kind: WorkspaceTab.Kind) -> UUID {
        guard isAcceptingNewConnections else { return UUID() }
        // 确保 Rust 侧有该主机的名称,用于标题消歧
        if let name = hostNameProvider(hostID) {
            workspaceSetHostNames(hostNames: [HostNameMapping(hostId: hostID, name: name)])
        }
        let ffiKind: TabKindEnum = kind == .terminal ? .terminal : .sftp
        guard let record = workspaceOpenTab(hostId: hostID, kind: ffiKind) else {
            return UUID()
        }
        syncFromFfi()
        return UUID(uuidString: record.id) ?? UUID()
    }

    /// 从 Rust FFI 同步标签列表、活动标签与待关闭状态到 @Published 属性。
    private func syncFromFfi() {
        let records = workspaceTabList()
        let newTabs = records.compactMap { record -> WorkspaceTab? in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return WorkspaceTab(
                id: id,
                hostID: record.hostId,
                kind: record.kind == .terminal ? .terminal : .sftp,
                title: record.title
            )
        }
        let newTabIDs = Set(newTabs.map(\.id))

        // 防御性去重 tabs：防止 FFI 返回重复记录导致 UI 渲染重复页签
        var seenTabIDs = Set<UUID>()
        let dedupedTabs = newTabs.filter { seenTabIDs.insert($0.id).inserted }

        // 更新 displayOrder：移除已关闭的页签，新增的追加到末尾
        displayOrder.removeAll(where: { !newTabIDs.contains($0) })
        for tab in dedupedTabs {
            if !displayOrder.contains(tab.id) {
                displayOrder.append(tab.id)
            }
        }
        // 防御性去重并保留顺序：防止任何路径导致 displayOrder 含重复 UUID
        var seen = Set<UUID>()
        displayOrder = displayOrder.filter { seen.insert($0).inserted }

        tabs = dedupedTabs
        syncGroupsFromFfi()

        if let activeStr = workspaceActiveTabId() {
            activeTabID = UUID(uuidString: activeStr)
        } else {
            activeTabID = nil
        }
        // 同步 Rust 侧待关闭状态(Swift 侧设置的 pendingCloseTabID/pendingBatchClose 优先)
        syncPendingCloseFromRust()
    }

    /// 从核心同步分组状态到本地 @Published 属性。
    private func syncGroupsFromFfi() {
        let snapshot = workspaceGroupSnapshot()
        let newTabIDs = Set(tabs.map(\.id))
        groups = snapshot.groups.compactMap { record -> TabGroup? in
            guard let id = UUID(uuidString: record.id) else { return nil }
            let tabIDs = record.tabIds.compactMap { UUID(uuidString: $0) }.filter { newTabIDs.contains($0) }
            return TabGroup(id: id, name: record.name, tabIDs: tabIDs)
        }
        ungroupedTabIDs = snapshot.ungroupedTabIds.compactMap { UUID(uuidString: $0) }.filter { newTabIDs.contains($0) }
    }

    /// 从 Rust 读取待关闭状态并更新 Swift 侧 @Published 属性。
    /// 核心是待关闭状态的唯一来源；Swift 侧仅转发呈现。
    private func syncPendingCloseFromRust() {
        guard let pending = workspacePendingClose() else {
            pendingCloseTabID = nil
            pendingBatchClose = nil
            return
        }
        let pendingIDs = Set(pending.tabIds.compactMap { UUID(uuidString: $0) })
        let count = Int(pending.connectedTerminalCount)

        if !pending.isBatch, pendingIDs.count == 1, let id = pendingIDs.first {
            pendingCloseTabID = id
            pendingBatchClose = nil
        } else if !pendingIDs.isEmpty {
            pendingCloseTabID = nil
            let allTabIDs = Set(tabs.map(\.id))
            let nonPending = allTabIDs.subtracting(pendingIDs)
            if nonPending.count == 1, let keeping = nonPending.first {
                pendingBatchClose = PendingBatchClose(scope: .others(keeping: keeping), connectedTerminalCount: count)
            } else {
                pendingBatchClose = PendingBatchClose(scope: .all, connectedTerminalCount: count)
            }
        }
    }

    /// 从核心同步标签快照，检测消失的标签并释放其会话资源。
    /// `previousTabIDs` 为操作前的标签集合；差集中不再存在的标签即被关闭。
    private func syncAndReleaseSessions(previousTabIDs: Set<UUID>) {
        let removedTabs = tabs.filter { previousTabIDs.contains($0.id) }
        syncFromFfi()
        let currentTabIDs = Set(tabs.map(\.id))
        for removedTab in removedTabs {
            guard !currentTabIDs.contains(removedTab.id) else { continue }
            if let session = terminalSessions.removeValue(forKey: removedTab.id)?.value {
                session.close()
            }
            sftpSessions.removeValue(forKey: removedTab.id)
            closeSessionHandler(removedTab)
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
