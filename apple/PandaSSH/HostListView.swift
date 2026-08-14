import SwiftUI

/// 根视图:侧栏 + 主区(工作区/片段),toast 挂在最顶层。
/// macOS 设置走原生 Settings Scene(cmd+,),iPadOS 走侧栏入口 + sheet。
struct HostListView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var toast = ToastCenter()

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            // 工作区容器常驻(标签栏始终在顶部);
            // 内容区按侧栏入口在 工作区/片段 之间切换。
            WorkspaceView()
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
