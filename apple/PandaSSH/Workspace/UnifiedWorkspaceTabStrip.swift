// =============================================================================
// UnifiedWorkspaceTabStrip.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了工作区顶部的「统一页签栏」(Unified Workspace Tab Strip)。
// 它是整个应用最顶端的 chrome 区域，负责：
//   1. 以页签按钮的形式展示所有已打开的工作区标签（终端、SFTP 等）。
//   2. 页签按分组 (group) 排列，分组之间有竖线分隔符。
//   3. 当页签过多导致溢出时，左右各出现一个「浏览按钮」(chevron) 用于横向滚动。
//   4. 支持页签的拖拽重排序（drag & drop）。
//   5. 支持页签的右键菜单（macOS 用 NSMenu，iPadOS 用 .contextMenu）。
//   6. macOS 专有：截获鼠标滚轮事件实现横向滚动（因为 SwiftUI 的横向 ScrollView
//      默认不响应普通鼠标的垂直滚轮）。
//
// 主要类型：
//   - UnifiedWorkspaceTabStrip: 主视图，页签栏本体。
//   - MacOSTabStripWheelBridge: macOS 专用 NSViewRepresentable，监听滚轮事件。
//   - UnifiedTabFramePreference / NaturalDocumentWidthPreference: PreferenceKey，
//     用于子视图向父视图上报几何信息（每个页签的 frame、文档自然宽度）。
//   - TabDropDelegate: DropDelegate 实现，处理页签拖拽排序。
//   - TabDragReorderSession: ObservableObject，管理单次拖拽的 UI 生命周期。
// =============================================================================

import SwiftUI
// macOS 平台需要导入 AppKit，因为用到了 NSView、NSEvent、NSMenu 等原生类型
#if os(macOS)
import AppKit
#endif

/// 统一顶部 chrome 使用的独立页签容器。
/// 浏览按钮只改变容器的可见锚点；只有页签按钮会改变活动页签或会话呈现。
struct UnifiedWorkspaceTabStrip: View {
    // ── 环境对象 ──
    /// AppModel: 应用全局状态模型，包含后端引用、工作区呈现状态等
    @EnvironmentObject private var model: AppModel
    /// WorkspaceStore: 工作区数据仓库，管理所有页签、分组、活动页签等
    @EnvironmentObject private var workspace: WorkspaceStore
    /// 浏览锚点：当前浏览按钮定位到的页签 ID，用于左右翻页时记住位置
    @State private var browseAnchorID: UUID?
    /// 每个页签的 frame（在文档坐标系中），由 PreferenceKey 从子视图收集上来
    @State private var tabFrames: [UUID: CGRect] = [:]
    /// 视口宽度（即页签栏容器的可见区域宽度）
    @State private var viewportWidth = 0.0
    /// 页签文档的自然宽度（所有页签排在一起的总宽度，含 padding）
    @State private var measuredDocumentWidth = 0.0
    /// 当前横向滚动偏移量
    @State private var viewportOffset = 0.0
    /// 拖拽重排序会话管理器（@StateObject 保证生命周期与视图一致）
    @StateObject private var dragReorder = TabDragReorderSession()

    // ── 静态常量 ──
    /// 文档坐标空间的名称，用于 GeometryReader 在统一坐标系中报告 frame
    private static let documentCoordinateSpace = "unified-workspace-tab-document"
    /// 文档左右内边距，复用 TabStripViewportState 中的 revealPadding 值
    private static let documentHorizontalPadding = TabStripViewportState.revealPadding
    /// 单个浏览按钮（左/右 chevron）的宽度（28pt）
    private static let browseButtonWidth = 28.0

    // ── 视图主体 ──
    var body: some View {
        // ScrollViewReader 提供 ScrollViewProxy，可通过编程方式 scrollTo 指定页签
        ScrollViewReader { proxy in
            Group {
                // ── 空状态：没有任何页签时，显示提示文字 ──
                if workspace.tabs.isEmpty {
                    // HStack 水平排列图标和文字，间距 6pt
                    HStack(spacing: 6) {
                        // 系统图标：两个矩形叠加，表示「无页签」
                        Image(systemName: "rectangle.on.rectangle")
                            // .foregroundStyle(.secondary) 使用系统二级前景色（灰色），让图标不那么醒目
                            .foregroundStyle(.secondary)
                        // 提示文字，同样使用二级灰色
                        Text("暂无已打开页签")
                            .foregroundStyle(.secondary)
                        // Spacer 把以上内容推到左侧，右侧留白
                        Spacer(minLength: 0)
                    }
                    // .font(.callout) 使用系统 callout 字号（约 16pt），比正文略小
                    .font(.callout)
                    // .padding(.horizontal, 12) 左右各加 12pt 内边距
                    .padding(.horizontal, 12)
                    // .accessibilityLabel 为 VoiceOver 提供无障碍标签
                    .accessibilityLabel("暂无已打开页签")
                } else {
                    // ── 有页签时的布局 ──
                    // GeometryReader 获取容器的实际尺寸，用于判断内容是否溢出
                    GeometryReader { containerProxy in
                        // 容器可见区域宽度
                        let containerWidth = containerProxy.size.width
                        // 使用文档自然宽度判断溢出；未测量时回退容器宽度，
                        // 避免把未测量当成真实零宽去预留整栏空白。
                        let effectiveContentWidth = measuredDocumentWidth > 0
                            // 已测量：用真实自然宽度
                            ? measuredDocumentWidth
                            // 未测量：回退为容器宽度（假设不溢出）
                            : containerWidth
                        // 根据内容宽度、视口宽度和当前偏移量，计算视口状态
                        // （是否需要滚动、当前偏移是否合法等）
                        let viewport = TabStripViewportState.resolve(
                            contentWidth: effectiveContentWidth,
                            viewportWidth: containerWidth,
                            offset: viewportOffset
                        )

                        if viewport.needsScroll {
                            // ── 内容溢出：需要横向滚动 ──
                            // 布局为：[左浏览按钮] [ScrollView 页签文档] [右浏览按钮]
                            HStack(spacing: 0) {
                                // 左浏览按钮（chevron.left），点击向左滚动
                                browseButton(systemName: "chevron.left", direction: -1, proxy: proxy)
                                // ScrollView 横向滚动容器，showsIndicators: false 隐藏底部滚动条
                                ScrollView(.horizontal, showsIndicators: false) {
                                    tabDocument
                                        // .fixedSize(horizontal: true) 让文档按内容自然宽度展开，不被压缩
                                        .fixedSize(horizontal: true, vertical: false)
                                        // .padding(.horizontal) 文档左右留白，防止第一个/最后一个页签贴边
                                        .padding(.horizontal, Self.documentHorizontalPadding)
                                        // .padding(.vertical, 5) 文档上下留 5pt 边距
                                        .padding(.vertical, 5)
                                        // .coordinateSpace 命名坐标空间，供子视图 GeometryReader 报告 frame
                                        .coordinateSpace(name: Self.documentCoordinateSpace)
                                        // .background 放一个宽度报告器，测量文档自然宽度
                                        .background(documentWidthReporter)
                                }
                                // 限制 ScrollView 最大宽度 = 容器宽度 - 两个浏览按钮宽度
                                .frame(maxWidth: max(0, containerWidth - Self.browseButtonWidth * 2))
                                // 右浏览按钮（chevron.right），点击向右滚动
                                browseButton(systemName: "chevron.right", direction: 1, proxy: proxy)
                            }
                        } else {
                            // ── 内容不溢出：无需滚动 ──
                            // 文档按自然宽度展示，右侧空白区域可拖拽窗口
                            HStack(spacing: 0) {
                                tabDocument
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, Self.documentHorizontalPadding)
                                    .padding(.vertical, 5)
                                    .coordinateSpace(name: Self.documentCoordinateSpace)
                                    .background(documentWidthReporter)
                                // Spacer 占据剩余空间
                                Spacer(minLength: 0)
                                    // .contentShape(Rectangle()) 让空白区域也能接收点击/拖拽事件
                                    .contentShape(Rectangle())
                                    // .frame(maxHeight: .infinity) 让空白区域纵向撑满
                                    .frame(maxHeight: .infinity)
                                    // .macOSWindowDragRegion() 标记为 macOS 窗口拖拽区域（可拖拽窗口移动）
                                    .macOSWindowDragRegion()
                            }
                        }
                    }
                    // 背景中放一个容器宽度报告器，实时追踪容器宽度变化
                    .background(containerWidthReporter)
                }
            }
            // .macOSTabStripWheelBridge 在 macOS 上桥接滚轮事件，实现鼠标滚轮横向翻页签
            .macOSTabStripWheelBridge { input in
                // 收到滚轮输入后，计算目标偏移并滚动
                scroll(to: currentViewport.targetOffset(after: input), using: proxy)
            }
            // .onAppear 视图首次出现时，滚动到当前活动页签使其可见
            .onAppear { revealActiveTab(using: proxy) }
            // .onChange 当活动页签 ID 变化时（如用户点击了某个页签），自动滚动使其可见
            .onChange(of: workspace.activeTabID) { _, _ in revealActiveTab(using: proxy) }
            // .onChange 当页签列表变化时（增删页签），重新规范化浏览锚点并滚动到活动页签
            .onChange(of: workspace.tabs.map(\.id)) { _, _ in
                normalizeBrowseAnchor()
                revealActiveTab(using: proxy)
            }
            // .onPreferenceChange 监听子视图上报的每个页签 frame，更新 tabFrames 字典。
            // ⚠️ 关键：只有 frames 真正变化了才赋值！
            // 否则每次重建都会新建字典实例，@State 赋值触发重建 → GeometryReader → 又发新值 → cycle
            .onPreferenceChange(UnifiedTabFramePreference.self) { frames in
                if frames != tabFrames {
                    tabFrames = frames
                }
            }
        }
        #if os(macOS)
        // NonWindowDraggingView 做两件事：
        // 1. 自身 override mouseDownCanMoveWindow = false 作为局部阻断
        // 2. 挂到 window 后 swizzle NSHostingView 做全局阻断
        .background(NonWindowDraggingView())
        #endif
        // .onDisappear 视图消失时（如窗口关闭），取消正在进行的拖拽重排序
        .onDisappear { dragReorder.cancel(workspace: workspace) }
        // .accessibilityIdentifier 为 UI 测试提供无障碍标识符
        .accessibilityIdentifier("unified-workspace-tab-strip")
    }

    // ── 页签文档区域：所有页签按钮按分组排列 ──
    // @ViewBuilder 允许在函数体内使用 if/for 等控制流构建视图
    @ViewBuilder
    private var tabDocument: some View {
        // HStack 水平排列所有分组和页签，间距 4pt
        HStack(spacing: 4) {
            // 遍历所有分组（groups），enumerated() 提供索引和分组对象
            ForEach(Array(workspace.groups.enumerated()), id: \.element.id) { groupIndex, group in
                // 如果不是第一个分组，或者存在未分组的页签，则插入分隔线
                if groupIndex > 0 || !workspace.ungroupedTabIDs.isEmpty {
                    groupSeparator
                }
                // 显示分组名称标签（如「开发」「运维」等）
                groupLabel(group.name)
                // 遍历该分组内的所有页签 ID
                ForEach(group.tabIDs, id: \.self) { tabID in
                    // 根据 tabID 找到对应的 WorkspaceTab 对象
                    if let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                        // 渲染可拖拽的页签按钮
                        draggableTabButton(tab)
                    }
                }
            }
            // 如果存在未分组的页签，且也有分组，则在未分组页签前插入分隔线
            if !workspace.ungroupedTabIDs.isEmpty && !workspace.groups.isEmpty {
                groupSeparator
            }
            // 遍历未分组的页签（不属于任何分组的页签）
            ForEach(workspace.ungroupedTabIDs, id: \.self) { tabID in
                if let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                    draggableTabButton(tab)
                }
            }
        }
    }

    /// 创建可拖拽的页签按钮：在普通页签按钮基础上叠加拖拽排序能力。
    ///
    /// 关键：.onTapGesture、.contentShape 和 .onDrag 必须在**完全相同的视图层级**上
    /// 才能正确竞争。如果 .onTapGesture 在子视图而 .onDrag 在父视图，SwiftUI
    /// 的子视图手势优先规则会让 .onTapGesture 总是先识别，吞掉 mouseDown，
    /// .onDrag 永远没机会启动。
    ///
    /// 所以 .contentShape 和 .onTapGesture 从 tabButton 内部移到了这里，
    /// 紧挨着 .onDrag，让它们真正同级竞争：
    ///   快速点击 → .onTapGesture 先赢
    ///   长按拖动 → .onDrag 先赢
    private func draggableTabButton(_ tab: WorkspaceTab) -> some View {
        tabButton(tab)
            // .id(tab.id) 为每个页签设置唯一 ID，ScrollViewReader 的 scrollTo 依赖此 ID 定位页签
            .id(tab.id)
            // .contentShape 让整个 HStack 的区域（包括背景）都可点击/拖拽
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            // .onTapGesture 点击页签时选中此页签。
            // ⚠️ 必须和下面的 .onDrag 在同一视图层级！
            .onTapGesture {
                print("🔥 onTap fired for tab \(tab.id)")
                workspace.select(tabID: tab.id)
                model.presentTab(tab.id)
            }
            // .background 放一个 frame 报告器，将页签在文档坐标系中的 frame 上报给父视图
            .background(tabFrameReporter(for: tab.id))
            // 拖拽中的页签半透明显示（opacity 0.5），让用户知道它正在被拖拽
            .opacity(dragReorder.draggingTabID == tab.id ? 0.5 : 1.0)
            // .onDrag 当用户开始拖拽此页签时触发
            // ⚠️ 必须和上面的 .onTapGesture 在同一视图层级竞争
            .onDrag {
                print("🔥 onDrag fired for tab \(tab.id)")
                // 通知 dragReorder 会话开始拖拽此页签
                dragReorder.begin(tabID: tab.id, workspace: workspace)
                // 返回 NSItemProvider，携带页签 ID 字符串作为拖拽数据
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            // .onDrop 注册放置代理：当其他页签拖拽到此页签上方时，触发排序逻辑
            // ⚠️ UTI 必须同时包含 .text 和 .plainText！
            // NSString as NSItemProvider 注册的是 kUTTypePlainText（.plainText），
            // 不是 kUTTypeText（.text）。只写 [.text] 会因为 UTI 不匹配导致
            // dropEntered/performDrop 永远不被调用。
            .onDrop(of: [.text, .plainText], delegate: TabDropDelegate(
                // 放置目标页签 ID
                targetTabID: tab.id,
                // 工作区仓库
                workspace: workspace,
                // 拖拽会话管理器
                dragReorder: dragReorder
            ))
    }

    /// 创建浏览按钮（左/右 chevron），用于在页签溢出时横向翻页
    /// - Parameters:
    ///   - systemName: SF Symbols 图标名称（"chevron.left" 或 "chevron.right"）
    ///   - direction: 滚动方向，-1 为向左，+1 为向右
    ///   - proxy: ScrollViewProxy，用于编程式滚动
    private func browseButton(
        systemName: String,
        direction: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            // 点击时按指定方向移动浏览锚点
            moveBrowseAnchor(direction: direction, using: proxy)
        } label: {
            // 按钮内容：SF Symbols 图标
            Image(systemName: systemName)
                // .font(.system(size: 11, weight: .semibold)) 设置图标字号 11pt、半粗体
                .font(.system(size: 11, weight: .semibold))
                // .frame(width: 28, height: 28) 固定按钮尺寸为 28x28pt
                .frame(width: Self.browseButtonWidth, height: 28)
                // .contentShape(Rectangle()) 让整个 frame 区域都可点击（而非仅图标像素）
                .contentShape(Rectangle())
        }
        // .buttonStyle(.plain) 使用朴素按钮样式，不添加系统默认的按钮外观（背景、圆角等）
        .buttonStyle(.plain)
        // .disabled 当该方向已经无法继续滚动时，禁用按钮（变灰不可点击）
        .disabled(!canBrowse(direction: direction))
        // .accessibilityLabel 为 VoiceOver 提供中文无障碍描述
        .accessibilityLabel(direction < 0 ? "浏览前一页签" : "浏览后一页签")
    }

    /// 鼠标悬停中的页签 ID（用于显示悬停边框效果）
    @State private var hoveredTabID: UUID?
    #if os(macOS)
    /// macOS 右键菜单的 action handler（接收菜单项点击并转发到 workspace）
    @State private var tabMenuHandler: TabMenuActionHandler?
    #endif

    /// 创建单个页签按钮：由左侧标签区域 + 右侧关闭按钮组成
    /// 注意：.onTapGesture 和 .contentShape 已移到 draggableTabButton 外层，
    /// 与 .onDrag 在同一视图层级竞争。这里只负责渲染视觉元素和关闭按钮。
    private func tabButton(_ tab: WorkspaceTab) -> some View {
        // 判断当前页签是否处于鼠标悬停状态
        let isHovered = hoveredTabID == tab.id
        // 判断当前页签是否为活动页签（正在展示的页签）
        let active = isActive(tab)

        // 两个独立组件水平排列，各自管理自己的手势
        return HStack(spacing: 0) {
            // ── 左侧：文本标签区域（状态圆点 + 图标 + 标题）──
            labelArea(for: tab, active: active)

            // ── 右侧：关闭按钮（xmark 图标）──
            closeButton(for: tab, isHovered: isHovered)
        }
        // .font(.callout) 设置整个页签的默认字号为 callout（约 16pt）
        .font(.callout)
        // .background 为活动页签添加浅灰色圆角背景，非活动页签背景透明
        .background {
            // RoundedRectangle 圆角矩形，cornerRadius 7pt，连续曲线样式
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // 活动页签填充 14% 不透明度的主色（浅灰），非活动页签完全透明
                .fill(active ? Color.primary.opacity(0.14) : Color.clear)
        }
        // .overlay 在页签上方叠加边框描边：悬停时显示 15% 不透明度的细边框
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // strokeBorder 描边：悬停时 0.5pt 宽的 15% 不透明度边框，非悬停时透明
                .strokeBorder(Color.primary.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5)
        )
        // .onHover 监听鼠标悬停状态变化（macOS 上鼠标移入/移出）
        .onHover { hovered in
            // 鼠标进入时记录当前页签 ID，离开时清除
            hoveredTabID = hovered ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
        // .accessibilityLabel 为 VoiceOver 提供页签标题
        .accessibilityLabel(tab.title)
        #if os(macOS)
        // macOS: 右键点击页签时弹出 NSMenu 右键菜单
        .onTabRightClick { event in
            showTabContextMenu(for: tab, event: event)
        }
        #else
        // iPadOS: 长按页签时弹出系统 contextMenu
        .contextMenu {
            tabContextMenuContent(for: tab)
        }
        #endif
    }

    /// 左侧标签区域：状态圆点 + 图标 + 标题
    /// 点击选中逻辑已提升到 tabButton 的 HStack 层级（与外层 .onDrag 同级），
    /// 以避免子视图手势优先吞掉拖拽手势。
    private func labelArea(for tab: WorkspaceTab, active: Bool) -> some View {
        // HStack 水平排列状态圆点、图标、标题，间距 6pt
        HStack(spacing: 6) {
            // 状态指示圆点：6x6pt 的小圆圈，颜色反映连接状态
            Circle()
                // .fill 填充颜色：绿色=已连接，黄色=连接中，红色=失败，灰色=未激活
                .fill(statusColor(for: tab.id))
                // .frame(width: 6, height: 6) 固定圆点尺寸为 6x6pt
                .frame(width: 6, height: 6)
            // 页签类型图标：终端用 apple.terminal（Apple 官方终端图标，辨识度高），
            // SFTP 用 folder.fill（填充版文件夹，小尺寸下更清晰）
            Image(systemName: tab.kind == .terminal ? "apple.terminal" : "folder.fill")
                // .font(.caption2) 使用 caption2 字号（约 11pt），让图标小一些
                .font(.caption2)
                // .foregroundStyle(.secondary) 使用二级灰色，让图标不那么抢眼
                .foregroundStyle(.secondary)
            // 页签标题文字（如主机名）
            Text(tab.title)
                // .lineLimit(1) 限制为单行显示，超长时末尾截断并显示省略号
                .lineLimit(1)
        }
        // .padding(.horizontal, 9) 标签区域左右各留 9pt 内边距
        .padding(.horizontal, 9)
        // .frame(minHeight: 30) 最小高度 30pt，确保页签有足够的点击区域
        .frame(minHeight: 30)
        // .accessibilityAddTraits 为活动页签添加 .isSelected 无障碍特征
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// 右侧关闭按钮：独立 Button，仅触发 requestClose
    private func closeButton(for tab: WorkspaceTab, isHovered: Bool) -> some View {
        Button {
            // 点击关闭按钮时，请求 workspace 关闭此页签（可能触发二次确认）
            workspace.requestClose(tabID: tab.id)
        } label: {
            // 关闭图标：xmark（×）
            Image(systemName: "xmark")
                // .font(.caption.weight(.semibold)) caption 字号 + 半粗体，让 × 清晰可见
                .font(.caption.weight(.semibold))
                // .frame(width: 20, height: 20) 固定关闭按钮尺寸为 20x20pt
                .frame(width: 20, height: 20)
                // .contentShape 让整个 20x20 区域都可点击
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        // .buttonStyle(.plain) 朴素按钮样式，不添加系统默认外观
        .buttonStyle(.plain)
        // .foregroundStyle(.secondary) 图标使用二级灰色
        .foregroundStyle(.secondary)
        // .background 关闭按钮的背景色：悬停时稍深（10%），非悬停时极浅（4%）
        .background(
            Color.primary.opacity(isHovered ? 0.10 : 0.04),
            // 背景形状为 4pt 圆角矩形
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        // .overlay 叠加 0.5pt 宽的 10% 不透明度描边，给关闭按钮一个细微的边框
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        // .padding(.trailing, 6) 关闭按钮右侧留 6pt 外边距，与页签右边缘保持间距
        .padding(.trailing, 6)
        // .accessibilityLabel 为 VoiceOver 提供「关闭 xxx」的无障碍描述
        .accessibilityLabel("关闭 \(tab.title)")
    }

    /// 分组分隔符：一条 1pt 宽的垂直线，高度 24pt，用于分隔不同分组
    private var groupSeparator: some View {
        Rectangle()
            // .fill 填充 20% 不透明度的主色，形成淡灰色竖线
            .fill(Color.primary.opacity(0.2))
            // .frame(width: 1, height: 24) 竖线宽 1pt、高 24pt
            .frame(width: 1, height: 24)
            // .padding(.horizontal, 4) 竖线左右各留 4pt 间距
            .padding(.horizontal, 4)
    }

    /// 分组标签：显示分组名称，带淡灰色圆角背景
    private func groupLabel(_ name: String) -> some View {
        Text(name)
            // .font(.caption2) 使用 caption2 字号（约 11pt），比页签文字更小
            .font(.caption2)
            // .foregroundStyle(.secondary) 使用二级灰色文字
            .foregroundStyle(.secondary)
            // .padding(.horizontal, 6) 左右各留 6pt 内边距
            .padding(.horizontal, 6)
            // .padding(.vertical, 2) 上下各留 2pt 内边距
            .padding(.vertical, 2)
            // .background 淡灰色圆角背景（8% 不透明度），让分组标签与页签有视觉区分
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    /// 判断页签是否为当前活动页签（正在展示内容的页签）
    private func isActive(_ tab: WorkspaceTab) -> Bool {
        // 比较工作区当前呈现的页签 ID 是否与此页签匹配
        model.workspacePresentation == .tab(tabID: tab.id)
    }

    /// 根据连接状态返回状态圆点的颜色
    private func statusColor(for tabID: UUID) -> Color {
        switch workspace.connectionStatus(forTabID: tabID) {
        // 已连接：绿色
        case .connected: .green
        // 连接中：黄色
        case .connecting: .yellow
        // 连接失败：红色
        case .failed: .red
        // 未激活：半透明灰色
        case .inactive: Color.gray.opacity(0.6)
        }
    }

    // MARK: - 页签右键菜单

    #if os(macOS)
    /// macOS：构建 NSMenu 并在鼠标位置弹出右键菜单。
    private func showTabContextMenu(for tab: WorkspaceTab, event: NSEvent) {
        // 懒初始化 tabMenuHandler：首次右键时创建，之后复用
        if tabMenuHandler == nil {
            tabMenuHandler = TabMenuActionHandler(workspace: workspace)
        }
        // 使用 TabContextMenuBuilder 构建原生 NSMenu 对象
        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tab.id,
            tabKind: tab.kind,
            workspace: workspace,
            // 菜单项的 action 目标
            target: tabMenuHandler,
            action: #selector(TabMenuActionHandler.handleMenuItem(_:))
        )
        // 使用临时定位视图弹出菜单；事件已携带鼠标位置信息。
        let anchor = NSView(frame: .zero)
        // NSMenu.popUpContextMenu 在鼠标当前位置弹出菜单
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
    }
    #else
    /// iPadOS：`.contextMenu` 内容构建，使用 SwiftUI 的 Button/Label 组合
    @ViewBuilder
    private func tabContextMenuContent(for tab: WorkspaceTab) -> some View {
        let items = TabContextMenuBuilder.items(for: tab.kind)
        // 如果是终端类型页签，显示「重新连接」菜单项和分隔线
        if items.contains(.reconnect) {
            Button {
                // 重新连接：断开当前连接并重新建立 SSH 连接
                workspace.reconnectSession(tabID: tab.id)
            } label: {
                Label(TabMenuItem.reconnect.title, systemImage: TabMenuItem.reconnect.symbolName)
            }
            Divider()
        }
        // 「关闭标签页」菜单项
        Button {
            workspace.requestClose(tabID: tab.id)
        } label: {
            Label(TabMenuItem.closeTab.title, systemImage: TabMenuItem.closeTab.symbolName)
        }
        // 「关闭其他标签页」菜单项：关闭除当前页签外的所有页签
        Button {
            workspace.requestCloseOthers(keeping: tab.id)
        } label: {
            Label(TabMenuItem.closeOthers.title, systemImage: TabMenuItem.closeOthers.symbolName)
        }
        // 「关闭所有标签页」菜单项
        Button {
            workspace.requestCloseAll()
        } label: {
            Label(TabMenuItem.closeAll.title, systemImage: TabMenuItem.closeAll.symbolName)
        }
        Divider()
        // 分组操作：「新建分组」，将当前页签放入一个新分组
        Button {
            workspace.createGroup(forTabID: tab.id)
        } label: {
            Label(TabMenuItem.newGroup.title, systemImage: TabMenuItem.newGroup.symbolName)
        }
        // 移动到已有分组：遍历所有分组，每个分组一个菜单项
        ForEach(workspace.groups) { group in
            Button {
                workspace.moveTab(tab.id, toGroup: group.id)
            } label: {
                Label("移动到「\(group.name)」", systemImage: TabMenuItem.moveToGroup(groupID: group.id, groupName: group.name).symbolName)
            }
        }
        // 「取消分组」：将页签从当前分组中移出
        Button {
            workspace.removeTabFromGroup(tab.id)
        } label: {
            Label(TabMenuItem.ungroup.title, systemImage: TabMenuItem.ungroup.symbolName)
        }
    }
    #endif

    /// 按方向移动浏览锚点：计算下一个目标偏移量并滚动
    private func moveBrowseAnchor(direction: Int, using proxy: ScrollViewProxy) {
        let viewport = currentViewport
        // 将方向转换为离散滚动输入（.backward 或 .forward）
        let input: TabStripScrollInput = .discrete(direction < 0 ? .backward : .forward)
        // 计算滚动后的目标偏移量
        let targetOffset = viewport.targetOffset(after: input)
        scroll(to: targetOffset, using: proxy)
    }

    /// 判断指定方向是否还可以继续浏览（是否还有内容可滚动）
    private func canBrowse(direction: Int) -> Bool {
        let viewport = currentViewport
        // 如果目标偏移与当前偏移差异 > 0.5pt，说明还有内容可滚动
        return abs(viewport.targetOffset(after: .discrete(direction < 0 ? .backward : .forward)) - viewport.offset) > 0.5
    }

    /// 规范化浏览锚点：确保锚点 ID 仍然存在于页签列表中，否则回退到活动页签
    private func normalizeBrowseAnchor() {
        // 检查当前锚点是否仍然有效（对应的页签还存在）
        guard let browseAnchorID,
              workspace.tabs.contains(where: { $0.id == browseAnchorID }) else {
            // 锚点无效，回退为当前活动页签 ID
            self.browseAnchorID = workspace.activeTabID
            return
        }
    }

    /// 计算当前视口状态（内容宽度、视口宽度、偏移量的综合结果）
    private var currentViewport: TabStripViewportState {
        // 已测量文档宽度时使用测量值，否则回退到视口宽度
        let effectiveContentWidth = measuredDocumentWidth > 0
            ? measuredDocumentWidth
            : viewportWidth
        return TabStripViewportState.resolve(
            contentWidth: effectiveContentWidth,
            viewportWidth: viewportWidth,
            offset: viewportOffset
        )
    }

    /// 滚动到活动页签使其在视口中可见
    private func revealActiveTab(using proxy: ScrollViewProxy, animated: Bool = true) {
        // 获取活动页签 ID 和它在文档坐标系中的 frame
        guard let activeTabID = workspace.activeTabID,
              let frame = tabFrames[activeTabID] else { return }
        // 更新浏览锚点到活动页签
        browseAnchorID = activeTabID
        // 计算让活动页签可见所需的偏移量
        scroll(to: currentViewport.revealedOffset(
            // 页签左边缘在文档中的 x 坐标
            itemMinX: Double(frame.minX),
            // 页签右边缘在文档中的 x 坐标
            itemMaxX: Double(frame.maxX)
        ), using: proxy, animated: animated)
    }

    /// 执行滚动到目标偏移量
    private func scroll(to targetOffset: Double, using proxy: ScrollViewProxy, animated: Bool = true) {
        // 几何更新可能重复到达；没有实际位移时不触发 scrollTo 或新的动画。
        guard abs(targetOffset - viewportOffset) > 0.5 else { return }
        // 找到目标偏移量对应的页签和锚点位置
        guard let target = currentViewport.scrollTarget(
            for: targetOffset,
            among: tabFrames
        ) else { return }
        // 更新本地状态
        viewportOffset = targetOffset
        browseAnchorID = target.tabID
        // 计算锚点单位位置（0 = 左边缘对齐，1 = 右边缘对齐）
        let anchor = UnitPoint(x: target.anchorX, y: 0)
        if animated {
            // 带动画滚动：使用 withAnimation 包裹 scrollTo
            withAnimation { proxy.scrollTo(target.tabID, anchor: anchor) }
        } else {
            // 无动画滚动：创建禁用动画的事务
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target.tabID, anchor: anchor) }
        }
    }

    /// 创建页签 frame 报告器：用 GeometryReader 测量页签在文档坐标系中的 frame，
    /// 并通过 PreferenceKey 上报给父视图
    private func tabFrameReporter(for tabID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: UnifiedTabFramePreference.self,
                // proxy.frame(in: .named(...)) 获取此视图在命名坐标空间中的 frame
                value: [tabID: proxy.frame(in: .named(Self.documentCoordinateSpace))]
            )
        }
    }

    /// 文档宽度报告器：测量整个页签文档的自然宽度（含 padding），
    /// 用于判断是否需要横向滚动
    private var documentWidthReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: NaturalDocumentWidthPreference.self,
                // proxy.size.width 是文档的自然宽度
                value: [UUID(): proxy.size.width]
            )
        }
    }

    /// 容器宽度报告器：追踪页签栏容器的可见区域宽度变化
    private var containerWidthReporter: some View {
        GeometryReader { proxy in
            Color.clear
                // .onAppear 视图出现时记录初始容器宽度
                .onAppear { viewportWidth = proxy.size.width }
                // .onChange 容器宽度变化时更新（如窗口缩放）
                .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
        }
    }
}

#if os(macOS)
/// AppKit 输入适配只负责提取原始滚轮值；页签的边界和浏览规则仍由共享状态处理。
/// 将 NSEvent 的 horizontalDelta/verticalDelta/isPrecise 归一化为统一的 TabStripScrollInput
enum MacOSTabStripWheelInput {
    static func resolve(
        // 横向滚动增量（触控板/鼠标滚轮）
        horizontalDelta: Double,
        // 纵向滚动增量
        verticalDelta: Double,
        // 是否为精确滚动（触控板 = true，鼠标滚轮 = false）
        isPrecise: Bool
    ) -> TabStripScrollInput? {
        // 调用归一化方法，将原始滚轮值转换为统一的滚动输入
        TabStripScrollInput.normalize(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta,
            isPrecise: isPrecise
        )
    }
}

/// 在页签栏边界内截获滚轮事件，避免 SwiftUI 横向 ScrollView 忽略普通鼠标的垂直滚轮。
/// 这是一个 NSViewRepresentable，将 AppKit 的 NSView 桥接到 SwiftUI 中。
private struct MacOSTabStripWheelBridge: NSViewRepresentable {
    /// 收到滚轮输入时的回调闭包
    let onInput: (TabStripScrollInput) -> Void

    /// 创建 MonitorView 实例（首次创建时调用）
    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onInput = onInput
        return view
    }

    /// 视图更新时同步回调闭包（SwiftUI 重新渲染时调用）
    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onInput = onInput
    }

    /// 视图从 SwiftUI 树中移除时停止事件监听
    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    /// 内部 NSView 子类：使用 NSEvent.addLocalMonitorForEvents 监听滚轮事件
    final class MonitorView: NSView {
        /// 滚轮输入回调
        var onInput: ((TabStripScrollInput) -> Void)?
        /// 事件监听器的句柄（用于后续移除监听）
        private var monitor: Any?

        /// 视图被添加到窗口时开始监听滚轮事件
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startMonitoring()
        }

        /// 开始监听本地滚轮事件
        func startMonitoring() {
            // 先停止旧的监听（避免重复注册）
            stopMonitoring()
            // 必须在窗口中才能监听
            guard window != nil else { return }
            // 注册本地事件监听器，只监听 .scrollWheel（滚轮）事件
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window = self.window,
                      // 只处理当前窗口的事件（忽略其他窗口）
                      event.window === window else { return event }
                // 将事件坐标转换为当前视图的本地坐标
                let point = self.convert(event.locationInWindow, from: nil)
                // 检查鼠标是否在视图范围内内，且能解析为有效的滚动输入
                guard self.bounds.contains(point),
                      let input = MacOSTabStripWheelInput.resolve(
                          horizontalDelta: event.scrollingDeltaX,
                          verticalDelta: event.scrollingDeltaY,
                          isPrecise: event.hasPreciseScrollingDeltas
                      ) else { return event }
                // 触发回调，将滚动输入传递给页签栏
                self.onInput?(input)
                // 返回 nil 表示吞掉此事件（不再传递给其他视图）
                return nil
            }
        }

        /// 停止监听滚轮事件
        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        /// 析构时确保停止监听
        deinit {
            stopMonitoring()
        }
    }
}

/// View 扩展：提供 .macOSTabStripWheelBridge 修饰符，将滚轮监听视图放在背景层
private extension View {
    func macOSTabStripWheelBridge(
        onInput: @escaping (TabStripScrollInput) -> Void
    ) -> some View {
        // .background 将监听视图放在页签栏的背景层（不可见但可接收事件）
        background(MacOSTabStripWheelBridge(onInput: onInput))
    }
}
#else
/// iPadOS 平台：.macOSTabStripWheelBridge 为空操作（直接返回 self），
/// 因为 iPadOS 不需要截获滚轮事件
private extension View {
    func macOSTabStripWheelBridge(
        onInput _: @escaping (TabStripScrollInput) -> Void
    ) -> some View { self }
}
#endif

/// PreferenceKey：收集每个页签在文档坐标系中的 frame。
/// 每个页签通过 GeometryReader 上报自己的 frame，父视图合并所有页签的 frame 到字典中。
private struct UnifiedTabFramePreference: PreferenceKey {
    /// 默认值：空字典（没有页签上报 frame）
    static var defaultValue: [UUID: CGRect] = [:]

    /// 合并函数：当多个子视图同时上报 frame 时，合并到同一个字典中
    /// uniquingKeysWith 指定键冲突时保留新值
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// 报告页签文档的自然宽度（含 padding），用于判断是否需要滚动。
/// 与 UnifiedTabFramePreference 不同，它测量的是整个文档的未压缩宽度，
/// 而非单个页签在文档坐标系中的帧。
struct NaturalDocumentWidthPreference: PreferenceKey {
    /// 默认值：空字典
    static var defaultValue: [UUID: CGFloat] = [:]

    /// 合并函数：直接替换（只取最新的宽度值，不合并多个）
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value = nextValue()
    }
}

/// 页签拖拽放置代理：处理页签拖拽排序。
/// 使用事务模式：dropEntered 仅更新预览，performDrop 才提交。
private struct TabDropDelegate: DropDelegate {
    /// 放置目标页签 ID（拖拽到此页签上方时触发排序）
    let targetTabID: UUID
    /// 工作区仓库
    let workspace: WorkspaceStore
    /// 拖拽会话管理器
    let dragReorder: TabDragReorderSession

    /// 拖拽进入此页签区域时调用：预览移动效果（不真正提交排序变更）
    func dropEntered(info: DropInfo) {
        print("📥 dropEntered: target=\(targetTabID)")
        guard let draggingID = dragReorder.draggingTabID,
              draggingID != targetTabID else { return }
        // 预览将 draggingID 页签移动到 targetTabID 之前
        workspace.previewTabMove(draggingID, before: targetTabID)
    }

    /// 拖拽更新时调用：返回 .move 操作建议（告诉系统这是移动操作）
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    /// 拖拽释放时调用：提交排序变更
    func performDrop(info: DropInfo) -> Bool {
        print("📥 performDrop: target=\(targetTabID)")
        // 通知 dragReorder 提交排序变更
        dragReorder.commit(workspace: workspace)
        return true
    }
}

/// 单次页签拖放的 UI 生命周期。macOS 使用本地事件监视器捕获任何未提交的
/// 鼠标抬起或 Escape；回调延后一个主循环，确保目标的 performDrop 可先提交。
@MainActor
private final class TabDragReorderSession: ObservableObject {
    /// 当前正在拖拽的页签 ID（nil 表示没有拖拽进行中）
    @Published private(set) var draggingTabID: UUID?
    /// macOS 事件监听器句柄（监听鼠标抬起或 Escape 键）
    private var eventMonitor: Any?

    /// 析构时清理事件监听器
    deinit {
        #if os(macOS)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        #endif
    }

    /// 开始拖拽指定页签
    func begin(tabID: UUID, workspace: WorkspaceStore) {
        // 先取消之前的拖拽（如果有）
        cancel(workspace: workspace)
        // 记录正在拖拽的页签 ID
        draggingTabID = tabID
        // 通知 workspace 开始页签重排序（进入预览模式）
        _ = workspace.beginTabReorder(for: tabID)

        // ⚠️ 注意：不再注册全局 leftMouseUp 事件监听器。
        // 原因：它可能在 NSDraggingSession 处理 drop 之前就收到 leftMouseUp，
        // 导致 cancel() 在 performDrop 之前执行，把排序恢复回去。
        // NSDraggingSession 会自己检测鼠标释放并触发 performDrop。
        // Escape 取消可以用其他方式处理（或暂时不处理）。
    }

    /// 提交拖拽排序变更
    func commit(workspace: WorkspaceStore) {
        // 通知 workspace 提交待定的排序变更
        workspace.commitPendingTabReorder()
        finish()
    }

    /// 取消拖拽排序（恢复原始顺序）
    func cancel(workspace: WorkspaceStore) {
        // 通知 workspace 取消待定的排序变更
        workspace.cancelPendingTabReorder()
        finish()
    }

    /// 清理拖拽状态
    private func finish() {
        #if os(macOS)
        // 移除事件监听器
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        #endif
        eventMonitor = nil
        draggingTabID = nil
    }
}
