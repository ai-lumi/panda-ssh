import SwiftUI

/// 根视图:侧栏 + 主区(工作区/片段),toast 挂在最顶层。
/// macOS 下分栏结构由 WorkspaceView 持有(任务 4.2),本视图只做直通与 toast 挂载;
/// iPadOS 保持 NavigationSplitView 结构不变。
struct HostListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var toast = ToastCenter()
    #if os(macOS)
    @StateObject private var chromeMetrics = MacOSWorkspaceChromeMetrics()
    #endif
    var body: some View {
        #if os(macOS)
        WorkspaceView()
            .environmentObject(chromeMetrics)
            .environmentObject(toast)
            .toastOverlay(toast)
            // AppKit 宿主负责标题栏安全区、红绿灯与唯一顶行的窗口属性。
            .background(MainWindowChrome(metrics: chromeMetrics))
            // 侧栏弹层统一挂根视图，右键菜单等入口在侧栏隐藏时仍可弹出。
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
#if os(macOS)
#Preview("Mac 常规窗口") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .frame(width: 1180, height: 760)
}

#Preview("Mac 深色异常状态") {
    let model: AppModel = {
        let value = AppModel.previewModel()
        value.selectHost("h-mismatch")
        return value
    }()
    HostListView()
        .environmentObject(model)
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .preferredColorScheme(.dark)
        .frame(width: 1180, height: 760)
}
#else
#Preview("iPad 横屏常规宽度") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .frame(width: 1024, height: 768)
}

#Preview("iPad 紧凑分屏") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .frame(width: 520, height: 768)
}


#Preview("iPad Dynamic Type 与异常状态") {
    let model: AppModel = {
        let value = AppModel.previewModel()
        value.selectHost("h-mismatch")
        return value
    }()
    HostListView()
        .environmentObject(model)
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .environment(\.dynamicTypeSize, .accessibility2)
        .frame(width: 520, height: 768)
}
#endif
#endif
