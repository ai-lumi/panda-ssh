// ============================================================
// 文件: HostListView.swift
// 功能: 应用的主视图容器，负责构建整体界面布局。
//       macOS 平台下显示 WorkspaceView 工作区视图，并通过
//       AppKit 宿主窗口管理标题栏；iPadOS 平台下使用
//       NavigationSplitView 实现侧栏+详情的分栏导航结构。
//       同时挂载 toast 弹层（全局提示消息）和侧栏弹出表单。
// ============================================================

// 导入 SwiftUI 框架，提供声明式 UI 构建能力
import SwiftUI

/// 根视图:侧栏 + 主区(工作区/片段),toast 挂在最顶层。
/// macOS 下分栏结构由 WorkspaceView 持有(任务 4.2),本视图只做直通与 toast 挂载;
/// iPadOS 保持 NavigationSplitView 结构不变。
struct HostListView: View {
    // 从环境注入的全局应用状态模型，包含主机列表、选中状态、弹窗控制等
    @EnvironmentObject private var model: AppModel
    // 从环境注入的工作区存储，管理打开的终端/SFTP 标签页
    @EnvironmentObject private var workspace: WorkspaceStore
    // toast 消息中心，用 @StateObject 持有以确保生命周期与本视图一致
    @StateObject private var toast = ToastCenter()

    #if os(macOS)
    // 仅在 macOS 平台编译：跟踪窗口 chrome（标题栏、工具栏）的尺寸指标
    @StateObject private var chromeMetrics = MacOSWorkspaceChromeMetrics()
    #endif

    // body 属性定义视图的实际内容，SwiftUI 在状态变化时自动重新调用
    var body: some View {
        #if os(macOS)
        // ===== macOS 平台分支 =====
        // WorkspaceView 是 macOS 下的主工作区视图（包含任务列表、终端等）
        WorkspaceView()
            // 将窗口尺寸指标对象注入环境，子视图可读取以调整布局
            .environmentObject(chromeMetrics)
            // 将 toast 消息中心注入环境，任何子视图都能弹出提示
            .environmentObject(toast)
            // 在视图最顶层叠加 toast 浮层，用于显示全局提示消息
            .toastOverlay(toast)
            // AppKit 宿主负责标题栏安全区、红绿灯与唯一顶行的窗口属性。
            // 用 background 挂载 MainWindowChrome，它通过 AppKit 自定义窗口外观
            .background(MainWindowChrome(metrics: chromeMetrics))
            // 侧栏弹层统一挂根视图，右键菜单等入口在侧栏隐藏时仍可弹出。
            // .sheet(item:) 当 model.sidebarSheet 有值时弹出对应的表单面板
            .sheet(item: $model.sidebarSheet) { kind in
                // 根据弹层类型（新建分组/编辑主机等）渲染对应的表单内容
                kind.sheetContent(model: model, workspace: workspace, toast: toast)
            }
        #else
        // ===== iPadOS 平台分支 =====
        // NavigationSplitView 提供可折叠的双栏导航：左侧边栏 + 右侧详情区
        // columnVisibility 绑定到 model，允许程序化控制侧栏的显示/隐藏
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            // 左栏：侧栏视图，显示主机列表和分组树
            SidebarView()
                // 设置侧栏列宽：最小 220pt、理想 250pt、最大 400pt
                // 用户可拖拽调整列宽，但会被限制在这个范围内
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 400)
        } detail: {
            // 右栏：工作区视图，显示选中主机的终端/SFTP 等内容
            WorkspaceView()
        }
        // 将 toast 消息中心注入环境
        .environmentObject(toast)
        // 在视图顶层叠加 toast 浮层
        .toastOverlay(toast)
        // 弹出侧栏相关的表单（如新建分组、编辑主机等）
        .sheet(item: $model.sidebarSheet) { kind in
            kind.sheetContent(model: model, workspace: workspace, toast: toast)
        }
        // 全屏模态覆盖：当 model.isPresentingSettings 为 true 时全屏展示设置页
        .fullScreenCover(isPresented: $model.isPresentingSettings) {
            // 用 NavigationStack 包裹设置页，提供导航栏和工具栏支持
            NavigationStack {
                // 设置页面视图
                SettingsView()
                    // 注入应用状态模型
                    .environmentObject(model)
                    // 注入工作区存储
                    .environmentObject(workspace)
                    // 注入 toast 消息中心
                    .environmentObject(toast)
                    // 在导航栏上添加工具栏按钮
                    .toolbar {
                        // 在导航栏右侧（确认操作位置）放置按钮
                        ToolbarItem(placement: .confirmationAction) {
                            // "关闭"按钮，点击后将 isPresentingSettings 设为 false 以关闭设置页
                            Button("关闭") {
                                model.isPresentingSettings = false
                            }
                        }
                    }
            }
        }
        #endif
    }
}

// ============================================================
// 以下仅在 DEBUG 编译条件下生效，定义 Xcode Preview 预览
// 用于在 Xcode Canvas 中实时查看 UI 效果，不会打包进正式版
// ============================================================
#if DEBUG
#if os(macOS)
// ===== macOS 预览 =====

// 预览场景 1：Mac 常规窗口尺寸（1180x760），展示正常状态
#Preview("Mac 常规窗口") {
    HostListView()
        // 注入用于预览的假数据模型
        .environmentObject(AppModel.previewModel())
        // 注入用于预览的假工作区存储
        .environmentObject(WorkspaceStore.previewStore())
        // 注入文件传输存储（空实例，仅用于满足环境依赖）
        .transferStore(TransferStore())
        // 设置预览窗口尺寸为 1180x760 像素，模拟典型 Mac 窗口
        .frame(width: 1180, height: 760)
}

// 预览场景 2：Mac 深色模式 + 主机密钥不匹配的异常状态
#Preview("Mac 深色异常状态") {
    // 构造一个预选了异常主机（h-mismatch）的预览模型
    let model: AppModel = {
        // 创建带假数据的预览模型
        let value = AppModel.previewModel()
        // 选中 ID 为 "h-mismatch" 的主机，触发密钥不匹配的告警 UI
        value.selectHost("h-mismatch")
        return value
    }()
    HostListView()
        // 注入构造好的异常状态模型
        .environmentObject(model)
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        // 强制使用深色配色方案，预览深色模式下的视觉效果
        .preferredColorScheme(.dark)
        .frame(width: 1180, height: 760)
}
#else
// ===== iPadOS 预览 =====

// 预览场景 3：iPad 横屏常规宽度（1024x768），展示标准布局
#Preview("iPad 横屏常规宽度") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        // 模拟 iPad 横屏分辨率
        .frame(width: 1024, height: 768)
}

// 预览场景 4：iPad 紧凑分屏（520x768），测试窄屏下的自适应布局
#Preview("iPad 紧凑分屏") {
    HostListView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        // 模拟 iPad 分屏模式下的窄宽度，验证 UI 不会溢出
        .frame(width: 520, height: 768)
}


// 预览场景 5：iPad 大字号辅助功能 + 异常状态，测试 Dynamic Type 适配
#Preview("iPad Dynamic Type 与异常状态") {
    // 构造预选了异常主机的预览模型
    let model: AppModel = {
        let value = AppModel.previewModel()
        // 选中密钥不匹配的主机
        value.selectHost("h-mismatch")
        return value
    }()
    HostListView()
        .environmentObject(model)
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        // 将动态字体大小设为 accessibility2（比默认大很多），验证文字不会截断
        .environment(\.dynamicTypeSize, .accessibility2)
        .frame(width: 520, height: 768)
}
#endif
#endif
