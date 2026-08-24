import Foundation

/// 仅保存 SFTP 单栏视图当前显示哪一侧；目录、选中项、加载状态和传输任务仍由
/// `SftpSessionStore` / `TransferStore` 持有，因此改变宽度不会重建业务状态。
struct SFTPPresentationState: Equatable {
    enum Pane: String, CaseIterable, Identifiable {
        case local
        case remote

        var id: String { rawValue }
    }

    private(set) var layout: WorkspaceLayoutPolicy.SFTPPresentation
    private(set) var selectedPane: Pane

    init(layout: WorkspaceLayoutPolicy.SFTPPresentation, selectedPane: Pane = .local) {
        self.layout = layout
        self.selectedPane = selectedPane
    }

    var visiblePanes: [Pane] {
        layout == .dualPane ? [.local, .remote] : [selectedPane]
    }

    mutating func updateLayout(_ layout: WorkspaceLayoutPolicy.SFTPPresentation) {
        self.layout = layout
    }

    mutating func select(_ pane: Pane) {
        selectedPane = pane
    }
}
