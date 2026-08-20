import Foundation

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

/// 标签页工作区状态:持有标签数组与活动标签,负责打开/切换/关闭
/// 以及同主机标签标题的序号消歧。主机名通过注入的查询闭包解析,
/// 便于测试替换、也避免模型层反向依赖 AppModel。
/// 关闭最后一个指向某主机的标签页时,通过 `disconnectHandler` 通知调用方断开 SSH 连接。
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var activeTabID: UUID?

    /// 按 hostID 查询主机显示名;查不到(如主机已删除)时返回 nil,标题回退为 hostID。
    private let hostNameProvider: (String) -> String?
    /// 关闭最后一个指向某主机的标签页时调用,参数为 hostID。
    private let disconnectHandler: (String) -> Void

    init(
        hostNameProvider: @escaping (String) -> String?,
        disconnectHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.hostNameProvider = hostNameProvider
        self.disconnectHandler = disconnectHandler
    }

    /// 打开终端标签页。总是新建,不做按主机的去重。
    func openTerminal(hostID: String) {
        open(hostID: hostID, kind: .terminal)
    }

    /// 打开 SFTP 标签页。总是新建,不做按主机的去重。
    func openSFTP(hostID: String) {
        open(hostID: hostID, kind: .sftp)
    }

    /// 切换活动标签;标签不存在时忽略。
    func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    /// 关闭标签页;标签不存在时忽略。关闭活动标签后,活动标签优先落在
    /// 左侧相邻标签,越界(关闭的是第一个)则落在原索引位置,即原右侧邻居。
    /// 若关闭的是某主机的最后一个标签页,触发 disconnectHandler 断开 SSH 连接。
    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let hostID = tabs[index].hostID
        let closingActive = (activeTabID == tabID)
        tabs.remove(at: index)
        if closingActive {
            activeTabID = tabs.isEmpty ? nil : tabs[max(index - 1, 0)].id
        }
        // 若无同主机标签残留,显式断开该主机的 SSH 连接
        if !tabs.contains(where: { $0.hostID == hostID }) {
            disconnectHandler(hostID)
        }
        retitle()
    }

    private func open(hostID: String, kind: WorkspaceTab.Kind) {
        let tab = WorkspaceTab(id: UUID(), hostID: hostID, kind: kind, title: "")
        tabs.append(tab)
        activeTabID = tab.id
        retitle()
    }

    /// 关闭某台主机的全部标签页(删除主机时级联清理,与原型一致)。
    func closeTabs(forHostID hostID: String) {
        let ids = tabs.filter { $0.hostID == hostID }.map(\.id)
        for id in ids { close(tabID: id) }
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
