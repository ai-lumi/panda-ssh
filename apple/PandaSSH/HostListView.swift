import SwiftUI

/// 根视图:侧栏 + 主区(工作区/片段/设置)+ 底部状态栏,toast 挂在最顶层。
/// 与原型窗口结构一致:标题栏以下为「侧栏 | 内容区」,窗口底部为状态栏。
struct HostListView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var toast = ToastCenter()

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                // 工作区容器常驻(标签栏始终在顶部,与原型一致);
                // 内容区按侧栏入口在 工作区/片段/设置 之间切换。
                WorkspaceView()
            }
            Divider()
            StatusBarView()
        }
        .environmentObject(toast)
        .toastOverlay(toast)
    }
}

#if DEBUG
#Preview("主界面") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .environmentObject(TransferStore())
}
#endif
