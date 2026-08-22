import SwiftUI

/// 根视图:侧栏 + 主区(工作区/片段),toast 挂在最顶层。
/// macOS 下分栏结构由 WorkspaceView 持有(任务 4.2),本视图只做直通与 toast 挂载;
/// iPadOS 保持 NavigationSplitView 结构不变。
struct HostListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var toast = ToastCenter()

    var body: some View {
        #if os(macOS)
        WorkspaceView()
            .environmentObject(toast)
            .toastOverlay(toast)
            // 移除系统工具栏(空白带/自带侧栏切换按钮),窗口顶部区域完全自绘。
            .background(MainWindowChrome())
            // 侧栏弹层统一挂根视图:入口按钮在侧栏顶部工具条,
            // 右键菜单等入口在侧栏隐藏时也要能弹出。
            .sheet(item: $model.sidebarSheet) { kind in
                kind.sheetContent(model: model, workspace: workspace, toast: toast)
            }
        #else
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 400)
        } detail: {
            WorkspaceView()
        }
        .environmentObject(toast)
        .toastOverlay(toast)
        .sheet(item: $model.sidebarSheet) { kind in
            kind.sheetContent(model: model, workspace: workspace, toast: toast)
        }
        #endif
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
