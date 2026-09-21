// =============================================================================
// 文件：UnifiedWorkspaceChrome.swift
// 功能：跨平台共享的工作区顶部栏（chrome）视图。
//       这个顶部栏包含以下组成部分（从左到右）：
//       1. 左侧安全预留区 —— 为 macOS 窗口交通灯按钮（红黄绿）预留空间
//       2. 侧栏工具按钮 —— "添加主机"、"新建分组"、"隐藏侧栏"三个按钮
//          或者侧栏恢复按钮 —— 当侧栏被隐藏时显示一个"显示侧栏"按钮
//       3. 页签条 —— 显示所有打开的终端标签页
//       4. 右侧安全预留区 —— 为 macOS 窗口工具栏预留空间
//       整个顶部栏高度固定为 40pt，背景使用 .bar 材质（半透明毛玻璃效果）。
//       macOS 上安全预留区还支持窗口拖动（macOSWindowDragRegion）。
// =============================================================================

// 导入 SwiftUI 框架
import SwiftUI

/// 跨平台共享的工作区顶部 chrome。
/// 平台宿主仅传入窗口安全预留宽度；页签、侧栏入口与业务状态均不分叉。
/// 这是一个 SwiftUI View 结构体，遵循 View 协议。
struct UnifiedWorkspaceChrome: View {
    /// 全局应用模型对象，通过 @EnvironmentObject 从视图环境中注入。
    /// 包含侧栏可见性、页签列表、会话状态等全局状态。
    /// 任何对 model 属性的修改都会自动触发相关视图刷新。
    @EnvironmentObject private var model: AppModel
    /// 左侧预留宽度（单位：点/pt）。
    /// macOS 上用于为窗口交通灯按钮（关闭/最小化/最大化）预留空间，
    /// 避免顶部栏内容与交通灯重叠。
    let leadingReservedWidth: Double
    /// 右侧预留宽度（单位：点/pt）。
    /// macOS 上用于为窗口工具栏按钮预留空间。
    let trailingReservedWidth: Double
    /// 是否显示自定义侧栏恢复按钮。
    /// 当侧栏被隐藏且此值为 true 时，在顶部栏左侧显示一个"显示侧栏"按钮。
    let showsCustomSidebarRecovery: Bool
    /// 侧栏的宽度（单位：点/pt）。
    /// 用于计算布局：当侧栏可见时，需要为侧栏工具按钮分配相应宽度。
    let sidebarWidth: Double

    /// 自定义初始化方法，所有参数都有默认值，可以灵活调用。
    /// 参数：
    ///   - leadingReservedWidth: 左侧预留宽度，默认 0
    ///   - trailingReservedWidth: 右侧预留宽度，默认 0
    ///   - sidebarWidth: 侧栏宽度，默认 0
    ///   - showsCustomSidebarRecovery: 是否显示侧栏恢复按钮，默认 true
    init(
        leadingReservedWidth: Double = 0,
        trailingReservedWidth: Double = 0,
        sidebarWidth: Double = 0,
        showsCustomSidebarRecovery: Bool = true
    ) {
        // 将传入的参数赋值给对应的存储属性
        self.leadingReservedWidth = leadingReservedWidth
        self.trailingReservedWidth = trailingReservedWidth
        self.sidebarWidth = sidebarWidth
        self.showsCustomSidebarRecovery = showsCustomSidebarRecovery
    }

    /// 视图的主体内容。SwiftUI 的 View 协议要求实现此属性。
    /// 返回值类型 some View 表示"某个遵循 View 协议的具体类型"。
    var body: some View {
        // GeometryReader：一个可以获取父容器尺寸的容器视图。
        // proxy 参数包含父容器的尺寸信息（宽度和高度）。
        GeometryReader { proxy in
            // 判断侧栏当前是否可见：如果 columnVisibility 不是 .detailOnly（仅显示详情区），
            // 说明侧栏正在显示。.detailOnly 表示侧栏被隐藏、只显示右侧内容区。
            let isSidebarVisible = model.columnVisibility != .detailOnly
            // 调用布局解析器，根据各种宽度参数计算出最终布局方案。
            // 返回的 layout 对象包含各部分（安全区、工具按钮、页签条）的精确宽度。
            let layout = UnifiedWorkspaceChromeLayout.resolve(
                // 窗口总宽度
                windowWidth: proxy.size.width,
                // 侧栏宽度
                sidebarWidth: sidebarWidth,
                // 侧栏是否可见
                isSidebarVisible: isSidebarVisible,
                // 左侧预留宽度
                leadingReservedWidth: leadingReservedWidth,
                // 右侧预留宽度
                trailingReservedWidth: trailingReservedWidth,
                // 是否全屏（暂固定为 false）
                isFullScreen: false,
                // 是否显示侧栏恢复按钮
                showsCustomSidebarRecovery: showsCustomSidebarRecovery
            )

            // HStack：水平排列子视图（从左到右），spacing: 0 表示子视图之间无间距。
            HStack(spacing: 0) {
                // 左侧安全预留区：
                // Color.clear 创建一个透明的色块
                Color.clear
                    // .frame(width:) 设置这个透明色块的宽度为布局计算出的左侧安全宽度
                    .frame(width: layout.leadingSafeWidth)
                    // .macOSWindowDragRegion() 让这个透明区域支持拖动窗口
                    // （macOS 特有功能，iOS 上是空操作）
                    .macOSWindowDragRegion()

                // 如果布局方案决定应该显示侧栏工具按钮（侧栏可见时）
                if layout.showsSidebarTools {
                    // 显示侧栏工具按钮组（添加主机、新建分组、隐藏侧栏）
                    sidebarTools
                        // .frame(width:alignment:) 设置固定宽度和对齐方式
                        // 宽度由布局计算决定，内容左对齐
                        .frame(width: layout.sidebarToolsWidth, alignment: .leading)
                        // .overlay(alignment:) 在视图上叠加一层覆盖层
                        // alignment: .trailing 表示覆盖层靠右对齐
                        .overlay(alignment: .trailing) {
                            // 在工具按钮右侧画一条竖线分隔符
                            // Rectangle() 创建一个矩形形状
                            Rectangle()
                                // .fill 设置填充颜色：primary 颜色的 12% 不透明度
                                // primary 会自动适配亮色/暗色模式（亮色下是黑色，暗色下是白色）
                                .fill(Color.primary.opacity(0.12))
                                // .frame(width:height:) 设置分隔线尺寸：宽 1pt、高 22pt
                                .frame(width: 1, height: 22)
                        }
                // 否则，如果布局方案决定应该显示侧栏恢复按钮（侧栏被隐藏时）
                } else if layout.showsSidebarRecovery {
                    // 显示侧栏恢复按钮（一个"显示侧栏"的图标按钮）
                    sidebarRecovery
                        // .frame(width:) 设置固定宽度
                        .frame(width: layout.sidebarRecoveryWidth)
                }

                // 页签条：显示所有打开的终端标签页
                UnifiedWorkspaceTabStrip()
                    // .frame(width:) 设置页签条的宽度，由布局计算决定
                    .frame(width: layout.tabStripWidth)

                // 窗口拖动只绑定到明确的空白区；不得覆盖页签或按钮，
                // 否则 AppKit 会在 SwiftUI 拖放启动前接管鼠标拖动。
                // 右侧安全预留区：
                // Color.clear 创建一个透明的色块
                Color.clear
                    // .frame(width:) 设置宽度为布局计算出的右侧安全宽度
                    .frame(width: layout.trailingSafeWidth)
                    // .macOSWindowDragRegion() 让这个区域支持拖动窗口
                    .macOSWindowDragRegion()
            }
            // .frame(maxWidth:maxHeight:alignment:) 设置整个 HStack 的最大尺寸和对齐方式
            // .infinity 表示尽可能占满可用空间，.leading 表示内容左对齐
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        // .frame(height:) 设置整个顶部栏的固定高度为 40pt
        .frame(height: 40)
        // .animation(nil, value:) 对特定值的变化禁用动画。
        // 这里传 nil 表示不做动画，value 是 model.columnVisibility。
        // 效果：侧栏显示/隐藏时，顶部栏宽度立即变化，不做平滑过渡动画。
        // 这样避免了页签和工具按钮在侧栏显隐时产生位移动画。
        .animation(nil, value: model.columnVisibility)
        // .background(.bar) 设置背景材质为 .bar（系统标准的工具栏材质）
        // 视觉效果：半透明毛玻璃效果，能透出后面的内容，macOS/iOS 都支持
        .background(.bar)
        // .accessibilityIdentifier() 为视图设置无障碍标识符，
        // 用于 UI 测试中定位此视图（类似 HTML 的 data-testid）
        .accessibilityIdentifier("unified-workspace-chrome")
    }

    /// 侧栏工具按钮组：包含"添加主机"、"新建分组"、"隐藏侧栏"三个按钮。
    /// 仅在侧栏可见时显示。
    private var sidebarTools: some View {
        // HStack(spacing: 4)：水平排列三个按钮，按钮之间间距 4pt
        HStack(spacing: 4) {
            // 第一个按钮："添加主机"
            Button {
                // 点击时设置 model.sidebarSheet 为 .addHost，
                // 触发弹出一个"添加主机"的表单弹窗（sheet）
                // defaultGroupID: nil 表示不预设分组（用户可在弹窗中选择）
                model.sidebarSheet = .addHost(defaultGroupID: nil)
            } label: {
                // Label：一个同时包含图标和文字的视图
                // "添加主机" 是按钮的无障碍标签（VoiceOver 会读出这个文字）
                // systemImage: "plus" 使用系统 SF Symbols 图标库中的加号图标
                Label("添加主机", systemImage: "plus")
            }
            // 第二个按钮："新建分组"
            Button {
                // 点击时设置 model.sidebarSheet 为 .newGroup，
                // 触发弹出一个"新建分组"的表单弹窗
                // parent: nil 表示在根级别创建分组（不是子分组）
                model.sidebarSheet = .newGroup(parent: nil)
            } label: {
                // 使用 "folder.badge.plus" 图标：一个带加号的文件夹图标
                Label("新建分组", systemImage: "folder.badge.plus")
            }
            // 第三个按钮："隐藏侧栏"
            Button {
                // 点击时将 columnVisibility 设为 .detailOnly（只显示详情区，隐藏侧栏）
                // withAnimation 包裹使变化带动画效果（侧栏平滑收起）
                withAnimation { model.columnVisibility = .detailOnly }
            } label: {
                // 使用 "sidebar.left" 图标：一个左侧栏图标，表示侧栏操作
                Label("隐藏侧栏", systemImage: "sidebar.left")
            }
        }
        // .labelStyle(.iconOnly)：只显示图标，不显示文字标签
        // 视觉效果：按钮只显示小图标，节省空间。文字仅用于无障碍（VoiceOver）
        .labelStyle(.iconOnly)
        // .buttonStyle(.plain)：使用朴素按钮样式
        // 视觉效果：去掉按钮的默认背景和高亮效果，只显示图标本身
        .buttonStyle(.plain)
        // .padding(.horizontal, 12)：水平方向（左右）添加 12pt 内边距
        // 视觉效果：按钮组左右各有 12pt 的空白，不会紧贴边缘
        .padding(.horizontal, 12)
        // .frame(maxWidth:alignment:)：宽度尽可能占满，内容左对齐
        .frame(maxWidth: .infinity, alignment: .leading)
        // .accessibilityElement(children: .contain)：将子视图组合为一个无障碍元素
        // .contain 表示 VoiceOver 仍然可以单独访问每个按钮，
        // 但也可以作为一组来导航
        .accessibilityElement(children: .contain)
    }

    /// 侧栏恢复按钮：当侧栏被隐藏时显示，点击后重新显示侧栏。
    /// 视觉上是一个小图标按钮，位于顶部栏最左侧。
    private var sidebarRecovery: some View {
        // 按钮：点击后显示侧栏
        Button {
            // 将 columnVisibility 设为 .all（显示所有列，包括侧栏）
            // withAnimation 使侧栏平滑展开
            withAnimation { model.columnVisibility = .all }
        } label: {
            // Image(systemName:) 使用 SF Symbols 系统图标
            // "sidebar.left" 是一个左侧栏图标
            Image(systemName: "sidebar.left")
                // .frame(width:height:) 设置图标的固定尺寸：宽 40pt、高 32pt
                // 视觉效果：给图标一个固定的点击区域，方便用户点击
                .frame(width: 40, height: 32)
        }
        // .buttonStyle(.plain)：朴素按钮样式，去掉默认背景和边框
        .buttonStyle(.plain)
        // .accessibilityLabel()：设置无障碍标签
        // VoiceOver 会读出"显示侧栏"，帮助用户理解这个图标的含义
        .accessibilityLabel("显示侧栏")
    }
}

// MARK: - macOS 窗口拖动区域扩展
// 条件编译：以下扩展仅在 macOS 平台编译
#if os(macOS)
extension View {
    /// 将视图标记为 macOS 窗口拖动区域。
    /// 用户在此区域按住鼠标拖动可以移动整个窗口。
    /// 返回值：添加了拖动功能的新视图
    func macOSWindowDragRegion() -> some View {
        // 拖窗视图必须位于明确的透明占位视图的命中测试前景。放在 background
        // 时，SwiftUI 的前景宿主可能先命中，导致 DragView 收不到鼠标按下。
        // overlay：在视图上方叠加一个 WindowDragView
        // WindowDragView 是一个原生 NSView 包装，专门处理窗口拖动
        overlay(WindowDragView())
    }
}
// 条件编译：iOS 平台
#else
extension View {
    /// iOS 平台上的空实现：不做任何操作，直接返回原视图。
    /// 因为 iOS 没有"拖动窗口"的概念，所以这个修饰符在 iOS 上什么都不做。
    func macOSWindowDragRegion() -> some View { self }
}
#endif
