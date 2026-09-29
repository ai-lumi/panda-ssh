// =============================================================================
// SidebarView.swift — 侧栏视图（搜索框 + 分组树 + 底部功能入口）
//
// 本文件实现应用左侧边栏的完整 UI，包括：
//   1. 搜索框：输入关键字过滤主机（macOS 在侧栏顶部，iPadOS 用系统 .searchable）
//   2. 分组树：以 OutlineGroup 渲染树形结构（分组 → 子分组/主机），支持展开折叠
//   3. 主机行：显示状态圆点 + 主机名 + 连接信息，右键菜单提供终端/SFTP/编辑等操作
//   4. 分组行：显示文件夹图标 + 分组名，右键菜单提供新建子分组/重命名/删除等操作
//   5. 底部入口：连接监控、传输任务、日志、设置（仅 iPadOS）等功能按钮
//   6. 删除确认：主机和分组的删除操作都会弹出确认对话框
//
// 侧栏的宽度、折叠等由 AppKit NSSplitViewController 管理（见 MainWindowChrome.swift）。
// =============================================================================

// 引入 SwiftUI 框架
import SwiftUI

/// 侧栏弹层枚举,供 SidebarView 与相关 sheet 共享。
/// 定义侧栏中可以弹出的所有模态对话框类型（sheet），每个关联项携带必要的数据。
/// 遵循 Identifiable 协议，以便 SwiftUI 的 .sheet(item:) 修饰符使用。
enum SidebarSheetKind: Identifiable {
    /// 添加新主机。defaultGroupID 为 nil 表示按当前选中态自动推断(选中分组 > 选中主机所在分组)
    case addHost(defaultGroupID: String?)
    /// 编辑已有主机，携带要编辑的主机数据
    case editHost(HostEntry)
    /// 复制已有主机（以现有主机为模板创建新主机），携带源主机数据
    case copyHost(HostEntry)
    /// 新建分组。parent 为 nil 表示在根级新建（不属于任何父分组）
    case newGroup(parent: HostGroup?)
    /// 重命名已有分组，携带要重命名的分组数据
    case renameGroup(HostGroup)

    /// 唯一标识符，用于 SwiftUI 的 .sheet(item:) 来识别不同的弹层
    /// 每种类型用不同的前缀 + 关联数据的 id 组成唯一字符串
    var id: String {
        switch self {
        // 添加主机：用分组 id 或 "auto"
        case .addHost(let gid): "addHost-\(gid ?? "auto")"
        // 编辑主机：用主机 id
        case .editHost(let host): "editHost-\(host.id)"
        // 复制主机：用源主机 id
        case .copyHost(let host): "copyHost-\(host.id)"
        // 新建分组：用父分组 id 或 "root"
        case .newGroup(let parent): "newGroup-\(parent?.id ?? "root")"
        // 重命名分组：用分组 id
        case .renameGroup(let group): "renameGroup-\(group.id)"
        }
    }
}

extension SidebarSheetKind {
    /// 根据弹层类型生成对应的 sheet 内容视图。
    /// @MainActor 确保在主线程执行（UI 操作必须在主线程）
    /// @ViewBuilder 允许使用 if/switch 等条件语句构建视图
    @MainActor
    @ViewBuilder
    func sheetContent(model: AppModel, workspace: WorkspaceStore, toast: ToastCenter) -> some View {
        switch self {
        case .addHost(let defaultGroupID):
            // 添加新主机：host 传 nil 表示新建模式，defaultGroupID 指定默认分组
            HostEditView(host: nil, defaultGroupID: defaultGroupID ?? model.groupIDForNewHost)
        case .editHost(let host):
            // 编辑已有主机：传入现有主机数据，表单会填充现有值
            HostEditView(host: host)
        case .copyHost(let host):
            // 复制主机：以现有主机为模板，表单会填充模板值但创建新记录
            HostEditView(copySource: host)
        case .newGroup(let parent):
            // 新建分组：弹出输入框让用户输入分组名称
            GroupNameSheet(
                // 标题根据是否有父分组而不同
                title: parent == nil ? "新建分组" : "新建子分组",
                // 提示信息
                message: parent.map { "在「\($0.name)」下创建子分组：" } ?? "在根级创建新分组："
            ) { name in
                // 用户确认后的回调：创建分组并显示成功提示
                model.createGroup(name: name, parentID: parent?.id)
                toast.show("分组已创建")
            }
        case .renameGroup(let group):
            // 重命名分组：弹出输入框，预填当前分组名称
            GroupNameSheet(title: "重命名分组", initial: group.name) { name in
                // 用户确认后的回调：执行重命名并显示成功提示
                model.renameGroup(id: group.id, name: name)
                toast.show("分组已重命名")
            }
        }
    }
}

/// 侧栏:搜索框 + 分组树 + 底部全局功能入口。
/// 布局与交互参照 prototype/index.html;右键菜单 macOS/iPadOS 统一走 contextMenu
/// (macOS 右键、iPadOS 长按)。
struct SidebarView: View {
    /// 应用数据模型（环境对象），包含所有主机配置、分组等数据
    @EnvironmentObject private var model: AppModel
    /// 传输队列以非订阅环境值取引用（不观察）：传输期间 5Hz 状态发布
    /// 不再使侧栏树（分组/主机列表/搜索）失效；角标数字由
    /// `TransferSideEntryButton` 小组件自行订阅刷新。
    /// 使用自定义环境键（而非 @EnvironmentObject）来避免高频刷新整个侧栏
    @Environment(\.transferStore) private var transfers
    /// 工作区状态（当前打开的标签页、选中的主机等）
    @EnvironmentObject private var workspace: WorkspaceStore
    /// 消息提示中心，用于显示操作成功/失败的短暂提示
    @EnvironmentObject private var toast: ToastCenter
    #if os(macOS)
    /// macOS 专用：用于打开新窗口（如连接监控窗口、日志窗口）
    @Environment(\.openWindow) private var openWindow
    /// macOS 专用：窗口度量数据（红绿灯宽度、侧栏宽度等）
    @EnvironmentObject private var chromeMetrics: MacOSWorkspaceChromeMetrics
    #endif

    /// 搜索框中的文本（空字符串表示未搜索）
    @State private var searchText = ""
    /// 等待用户确认删除的主机（非 nil 时弹出删除确认对话框）
    @State private var hostPendingDelete: HostEntry?
    /// 等待用户确认删除的分组（非 nil 时弹出删除确认对话框）
    @State private var groupPendingDelete: HostGroup?
    /// 侧栏行的动作回调集合，将用户操作（如打开终端、编辑主机等）传递给上层处理
    private var callbacks: SidebarCallbacks {
        SidebarCallbacks(
            // 打开终端标签
            openTerminal: { model.presentTab(workspace.openTerminal(hostID: $0.id)) },
            // 打开 SFTP 标签
            openSFTP: { model.presentTab(workspace.openSFTP(hostID: $0.id)) },
            // 弹出编辑主机表单
            editHost: { model.sidebarSheet = .editHost($0) },
            // 弹出复制主机表单
            copyHost: { model.sidebarSheet = .copyHost($0) },
            // 设置待删除主机（触发确认对话框）
            deleteHost: { hostPendingDelete = $0 },
            // 弹出新建子分组表单
            newSubgroup: { model.sidebarSheet = .newGroup(parent: $0) },
            // 弹出重命名分组表单
            renameGroup: { model.sidebarSheet = .renameGroup($0) },
            // 设置待删除分组（触发确认对话框）
            deleteGroup: { groupPendingDelete = $0 },
            // 在指定分组中添加主机
            addHostInGroup: { model.sidebarSheet = .addHost(defaultGroupID: $0.id) }
        )
    }

    /// 是否正在搜索（搜索文本去除空白后不为空）
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 搜索匹配的主机列表（调用 Rust 后端搜索函数，将结果转为 HostEntry）
    private var matchedHosts: [HostEntry] {
        // 搜索失败时返回空列表
        let records = (try? searchHosts(query: searchText)) ?? []
        // 将 FFI 记录转为 Swift 模型
        return records.map { HostEntry(record: $0) }
    }

    /// 侧栏的主体布局：垂直排列（搜索框 + 树形列表 + 分割线 + 底部入口）
    var body: some View {
        // 垂直堆叠，元素之间无间距（spacing: 0）
        VStack(spacing: 0) {
            #if os(macOS)
            // macOS：在侧栏顶部显示自定义搜索框
            searchField
            #endif
            // 分组树/主机列表（核心区域，占据大部分空间）
            treeView
            // 分割线：一条水平细线，视觉上分隔树形列表和底部入口
            Divider()
            // 底部功能入口按钮（连接监控、传输、日志等）
            bottomEntries
        }
        #if os(macOS)
        // 侧栏实际宽度仅作为 AppKit 标题栏宿主的布局测量，不承载业务状态。
        // .background 这里不是用来显示背景色，而是利用 GeometryReader 测量侧栏宽度
        .background(sidebarWidthReporter)
        // 顶部安全区由分栏宿主统一结算；子视图不能以负偏移抵消，否则会裁掉搜索框。
        // .ignoresSafeArea 让视图延伸到窗口顶部安全区域之外（标题栏区域）
        .ignoresSafeArea(.container, edges: .top)
        #endif
        #if os(iOS)
        // iPadOS：使用系统提供的 .searchable 修饰符添加搜索功能
        // placement: .sidebar 将搜索框放在侧栏顶部
        // prompt: 搜索框的占位文字
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机")
        // iPadOS 添加入口:macOS 在统一顶行提供操作,iPadOS 用系统导航栏按钮。
        // .toolbar 在导航栏右侧添加操作按钮
        .toolbar {
            // 第一个按钮：添加主机（加号图标）
            // .primaryAction 放在导航栏右侧主要位置
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // 弹出添加主机表单
                    model.sidebarSheet = .addHost(defaultGroupID: nil)
                } label: {
                    // 显示加号图标 + "添加主机"文字
                    Label("添加主机", systemImage: "plus")
                }
            }
            // 第二个按钮：新建分组（文件夹加号图标）
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // 弹出新建分组表单（根级）
                    model.sidebarSheet = .newGroup(parent: nil)
                } label: {
                    // 显示文件夹加号图标
                    Label("新建分组", systemImage: "folder.badge.plus")
                }
            }
        }
        #endif
        // 删除主机确认对话框：当 hostPendingDelete 不为 nil 时弹出
        .alert("删除主机", isPresented: hasPendingHost, presenting: hostPendingDelete) { host in
            // 取消按钮：关闭对话框，不执行删除
            Button("取消", role: .cancel) {}
            // 删除按钮（红色，destructive 角色）
            Button("删除", role: .destructive) {
                // 从数据模型中删除主机
                model.deleteHost(id: host.id)
                // 关闭该主机相关的所有标签页
                workspace.closeTabs(forHostID: host.id)
                // 显示成功提示
                toast.show("主机已删除")
            }
        } message: { host in
            // 对话框正文：警告用户操作不可撤销
            Text("确定删除「\(host.name)」吗？此操作不可撤销。")
        }
        // 删除分组确认对话框：当 groupPendingDelete 不为 nil 时弹出
        .alert("删除分组", isPresented: hasPendingGroup, presenting: groupPendingDelete) { group in
            // 取消按钮
            Button("取消", role: .cancel) {}
            // 删除按钮（红色）
            Button("删除", role: .destructive) {
                // 从数据模型中删除分组
                model.deleteGroup(id: group.id)
                // 显示提示：分组内的主机会被移到根级
                toast.show("分组已删除，主机已移回根级")
            }
        } message: { group in
            // 警告信息
            Text("确定删除分组「\(group.name)」吗？组内主机将移回根级，子分组将一并删除。")
        }
    }

    /// 将 hostPendingDelete 可选值转换为 Binding<Bool>，供 .alert 的 isPresented 参数使用
    /// get：当有等待删除的主机时返回 true（显示对话框）
    /// set：当对话框被关闭（$0 为 false）时，清空等待删除的主机
    private var hasPendingHost: Binding<Bool> {
        Binding(get: { hostPendingDelete != nil }, set: { if !$0 { hostPendingDelete = nil } })
    }

    /// 将 groupPendingDelete 可选值转换为 Binding<Bool>，逻辑同上
    private var hasPendingGroup: Binding<Bool> {
        Binding(get: { groupPendingDelete != nil }, set: { if !$0 { groupPendingDelete = nil } })
    }

    #if os(macOS)
    /// 侧栏宽度测量器：利用 GeometryReader 获取侧栏实际宽度，并上报给 chromeMetrics
    /// 这是一个不可见的背景层（Color.clear），仅用于测量尺寸
    private var sidebarWidthReporter: some View {
        // GeometryReader 可以获取父视图的尺寸信息
        GeometryReader { proxy in
            // 完全透明的视图（不可见）
            Color.clear
                // 视图首次出现时上报宽度
                .onAppear { chromeMetrics.updateSidebarWidth(proxy.size.width) }
                // 宽度变化时重新上报
                .onChange(of: proxy.size.width) { _, width in
                    chromeMetrics.updateSidebarWidth(width)
                }
        }
    }

    /// macOS 专用搜索框：放大镜图标 + 文本输入框，带圆角背景
    private var searchField: some View {
        // 水平排列：图标 + 文本框
        HStack {
            // 放大镜图标（SF Symbols）
            Image(systemName: "magnifyingglass")
                // 使用次要前景色（灰色），视觉上不太突出
                .foregroundStyle(.secondary)
            // 文本输入框，占位文字为"搜索主机"
            TextField("搜索主机", text: $searchText)
                // 使用纯文本样式（无系统默认边框）
                .textFieldStyle(.plain)
        }
        // 水平内边距 8pt（图标和文字不紧贴边缘）
        .padding(.horizontal, 8)
        // 垂直内边距 6pt（上下留出空间）
        .padding(.vertical, 6)
        // 圆角矩形背景，使用主色 6% 不透明度（非常淡的灰色）
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        // 搜索框整体与侧栏边缘的水平间距 10pt
        .padding(.horizontal, 10)
        // 搜索框底部与下方内容的间距 6pt
        .padding(.bottom, 6)
    }
    #endif

    // MARK: 分组树

    /// 节点树(分组 + 主机),由 Rust 后端组装,OutlineGroup 渲染。
    /// 调用 FFI 函数获取树形数据，将 FFI 记录转为 SidebarNode 供 SwiftUI 使用
    private var treeNodes: [SidebarNode] {
        // FFI 调用失败时返回空树
        ((try? sidebarTree()) ?? []).map { SidebarNode.from(ffiRecord: $0) }
    }

    /// List 选中态与 AppModel 的双向映射:节点 id 带 group-/host- 前缀,
    /// 选中主机/分组走各自的 select 方法(互斥,单一选中语义)。
    /// 这个 Binding 将 List 的选中值（String?）转换为 AppModel 的 selectedHostID/selectedGroupID
    private var nodeSelection: Binding<String?> {
        Binding(
            get: {
                // 读取当前选中状态：优先返回选中的主机，其次返回选中的分组
                // 带 "host-" 前缀
                if let hostID = model.selectedHostID { return SidebarNode.hostID(hostID) }
                // 带 "group-" 前缀
                if let groupID = model.selectedGroupID { return SidebarNode.groupID(groupID) }
                // 没有选中任何节点
                return nil
            },
            set: { newValue in
                // 用户在 List 中点击了某个节点时调用
                guard let raw = newValue, let parsed = SidebarNode.parse(id: raw) else { return }
                if parsed.isGroup {
                    // 选中分组（会取消主机选中）
                    model.selectGroup(parsed.rawID)
                } else {
                    // 选中主机（会取消分组选中）
                    model.selectHost(parsed.rawID)
                }
            }
        )
    }

    /// 原生树形组件:OutlineGroup 负责缩进、展开三角与层级渲染,
    /// List 负责选中高亮与滚动;搜索模式下平铺匹配结果。
    private var treeView: some View {
        // List 组件，支持行选中，选中绑定到 nodeSelection
        List(selection: nodeSelection) {
            if isSearching {
                // 搜索模式：平铺显示所有匹配的主机（不显示分组层级）
                if matchedHosts.isEmpty {
                    // 没有匹配的主机时显示提示文字
                    Text("无匹配主机")
                        // 小号字体
                        .font(.caption)
                        // 三级前景色（非常淡的灰色，视觉上不太突出）
                        .foregroundStyle(.tertiary)
                        // 水平方向占满整个宽度
                        .frame(maxWidth: .infinity)
                        // 四周内边距 16pt
                        .padding(16)
                } else {
                    // 有匹配结果：遍历显示每个匹配的主机行
                    ForEach(matchedHosts) { host in
                        // 主机行视图
                        HostRowView(host: host, callbacks: callbacks)
                            // 为 List 选中机制提供唯一标签
                            .tag(SidebarNode.hostID(host.id))
                    }
                }
            } else {
                // 正常模式：使用 OutlineGroup 渲染树形结构（分组可展开/折叠）
                OutlineGroup(treeNodes, children: \.children) { node in
                    // OutlineGroup 自动处理缩进、展开三角和层级关系
                    // children: \.children 指定子节点的属性路径
                    if let group = node.group {
                        // 如果节点是分组，显示分组行
                        GroupRowView(group: group, callbacks: callbacks)
                            // 为 List 选中提供标签
                            .tag(node.id)
                    } else if let host = node.host {
                        // 如果节点是主机，显示主机行
                        HostRowView(host: host, callbacks: callbacks)
                            .tag(node.id)
                    }
                }
            }
        }
        #if os(macOS)
        // macOS：使用纯列表样式（无系统侧栏背景色）
        .listStyle(.plain)
        #else
        // iPadOS：使用系统侧栏列表样式（带缩进和分组外观）
        .listStyle(.sidebar)
        #endif
        // 占据所有可用空间（宽度和高度都最大化）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部固定入口

    /// 底部功能入口按钮区域：垂直排列多个功能按钮
    private var bottomEntries: some View {
        // 垂直堆叠，按钮之间间距 2pt
        VStack(spacing: 2) {
            #if os(macOS)
            // macOS：连接监控按钮，点击后打开独立窗口
            SideEntryButton(
                // 按钮文字
                title: "连接监控",
                // 网络图标（SF Symbols）
                systemImage: "network",
                // macOS 上此按钮打开独立窗口，不存在「激活」状态
                isActive: false,
                action: {
                    // 设置侧栏页面状态
                    model.showConnectionMonitor()
                    // 打开连接监控独立窗口
                    openConnectionMonitorWindow()
                }
            )
            #else
            // iPadOS：连接监控按钮，点击后在侧栏内切换页面
            SideEntryButton(
                title: "连接监控",
                systemImage: "network",
                // 当前页面是连接监控时高亮
                isActive: model.sidebarPage == .connectionMonitor,
                action: model.showConnectionMonitor
            )
            #endif
            // 传输任务按钮：显示正在进行的传输任务数量（角标）
            TransferSideEntryButton(
                // 传输数据存储，用于获取活动任务数
                store: transfers,
                // 当前页面是传输时高亮
                isActive: model.sidebarPage == .transfers,
                action: {
                    // 设置侧栏页面状态
                    model.showTransfers()
                    #if os(macOS)
                    // macOS：同时打开传输独立窗口
                    openWindow(id: TransferWindow.id)
                    #endif
                }
            )
            #if os(iOS)
            // iPadOS 专用：设置按钮（macOS 的设置走 cmd+, 独立窗口，不在侧栏）
            SideEntryButton(
                title: "设置",
                // 齿轮图标
                systemImage: "gearshape",
                isActive: model.sidebarPage == .settings,
                action: model.showSettings
            )
            #endif
            #if os(macOS)
            // macOS：日志按钮，点击后打开独立日志窗口
            SideEntryButton(
                title: "日志",
                // 列表图标
                systemImage: "list.bullet.rectangle",
                // macOS 上打开独立窗口，不存在「激活」状态
                isActive: false,
                action: { openLogWindow() }
            )
            #else
            // iPadOS：日志按钮，在侧栏内切换页面
            SideEntryButton(
                title: "日志",
                systemImage: "list.bullet.rectangle",
                isActive: model.sidebarPage == .logs,
                action: model.showLogs
            )
            #endif
        }
        // 四周内边距 6pt，按钮不紧贴侧栏边缘
        .padding(6)
    }

    #if os(macOS)
    /// 打开连接监控窗口：优先激活已有窗口，避免重复打开
    private func openConnectionMonitorWindow() {
        // 与日志入口一致：优先激活已有窗口，避免重复打开。
        // 遍历所有窗口，找到标题匹配的窗口
        for window in NSApp.windows where window.title == ConnectionMonitorWindow.title {
            // 将已有窗口提到最前面并获得焦点
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 窗口不存在时通过 SwiftUI 创建新窗口
        openWindow(id: ConnectionMonitorWindow.id)
    }

    /// 打开日志窗口：优先激活已存在的日志窗口,否则由 SwiftUI 创建新窗口
    private func openLogWindow() {
        // 优先激活已存在的日志窗口,否则由 SwiftUI 创建新窗口
        // 遍历所有窗口，找到标题为"日志"的窗口
        for window in NSApp.windows where window.title == "日志" {
            // 将已有窗口提到最前面并获得焦点
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 窗口不存在时通过环境值打开（SwiftUI 的 WindowGroup 会创建新窗口）
        openWindow(id: "panda-log")
    }
    #endif
}

/// 侧栏行的动作回调集合,供递归节点视图向上传递菜单动作。
/// 将用户操作（打开终端、编辑主机等）封装为闭包，由侧栏统一实现，
/// 行视图只需调用回调，不需要知道具体实现细节（解耦）。
struct SidebarCallbacks {
    /// 打开终端：接受一个主机条目，执行打开终端操作
    var openTerminal: (HostEntry) -> Void
    /// 打开 SFTP 文件浏览器
    var openSFTP: (HostEntry) -> Void
    /// 编辑主机配置
    var editHost: (HostEntry) -> Void
    /// 复制主机（以现有主机为模板创建新主机）
    var copyHost: (HostEntry) -> Void
    /// 删除主机（通常先弹出确认对话框）
    var deleteHost: (HostEntry) -> Void
    /// 在指定分组下新建子分组
    var newSubgroup: (HostGroup) -> Void
    /// 重命名分组
    var renameGroup: (HostGroup) -> Void
    /// 删除分组
    var deleteGroup: (HostGroup) -> Void
    /// 在指定分组中添加主机
    var addHostInGroup: (HostGroup) -> Void
}

/// 主机行:状态圆点 + 两行(名称粗体 + user@host:port 灰小字)。
/// 作为 List/OutlineGroup 的行使用:单击选中由 List 负责,双击打开终端。
struct HostRowView: View {
    /// 应用数据模型，用于获取连接状态等信息
    @EnvironmentObject private var model: AppModel
    /// 工作区状态，用于查询当前主机的 SSH 连接状态
    @EnvironmentObject private var workspace: WorkspaceStore
    /// 要显示的主机数据
    let host: HostEntry
    /// 动作回调集合（右键菜单中的操作）
    let callbacks: SidebarCallbacks

    /// 状态圆点只表达当前已打开会话的可达性；主机密钥验证状态是独立安全信息，
    /// 不再以绿色伪装为"可连接"。
    /// 根据主机连接状态返回圆点颜色：已连接为绿色，其他状态为半透明灰色
    private var dotColor: Color {
        workspace.connectionStatus(forHostID: host.id) == .connected
            // 已连接：绿色圆点，表示活跃
            ? .green
            // 其他状态：半透明灰色，表示非活跃
            : Color(.gray).opacity(0.6)
    }

    /// 状态圆点的悬浮提示文字（macOS 上鼠标悬停时显示）
    private var dotTip: String {
        switch workspace.connectionStatus(forHostID: host.id) {
        // 绿色圆点提示
        case .connected: return "当前存在可用 SSH 会话"
        // 正在连接中
        case .connecting: return "正在建立 SSH 会话"
        // 连接失败
        case .failed: return "当前 SSH 会话不可达"
        // 未连接
        case .inactive: return "当前未建立 SSH 会话"
        }
    }

    /// 主机行的主体布局：水平排列（状态圆点 + 两行文字）
    var body: some View {
        // 水平堆叠，元素间距 8pt
        HStack(spacing: 8) {
            // 圆形（状态指示圆点）
            Circle()
                // 填充颜色（绿色=已连接，灰色=未连接）
                .fill(dotColor)
                // 圆点大小：7x7 像素（非常小的圆点）
                .frame(width: 7, height: 7)
                // macOS 上鼠标悬停时显示提示文字（tooltip）
                .help(dotTip)
            // 垂直堆叠文字，左对齐，行间距 1pt
            VStack(alignment: .leading, spacing: 1) {
                // 主机名称（第一行）
                Text(host.name)
                    // 字体：callout 大小 + 半粗体
                    .font(.callout.weight(.semibold))
                    // 限制为单行，超出部分显示省略号
                    .lineLimit(1)
                // 副标题（第二行，通常是 user@host:port）
                Text(host.subtitle)
                    // 字体：caption（较小的字号）
                    .font(.caption)
                    // 使用次要前景色（灰色），视觉上弱于主机名
                    .foregroundStyle(.secondary)
                    // 限制为单行
                    .lineLimit(1)
            }
            // 弹性空间：将左侧内容推到左边，自身占据剩余空间
            Spacer(minLength: 0)
        }
        // 垂直内边距 2pt（行与行之间有适当间距）
        .padding(.vertical, 2)
        // 让整个矩形区域都可响应点击/手势（而非仅文字区域）
        .contentShape(Rectangle())
        // 显式处理单击选中,避免 OutlineGroup 中行手势与 List 选中冲突。
        // .simultaneousGesture 允许此手势与其他手势（如 List 的选中）同时生效
        // 单击选中此主机
        .simultaneousGesture(TapGesture(count: 1).onEnded { model.selectHost(host.id) })
        // .contextMenu 添加右键菜单（macOS 右键 / iPadOS 长按触发）
        .contextMenu { hostMenu }
        // 无障碍相关：将子元素合并为一个无障碍元素
        .accessibilityElement(children: .combine)
        // 无障碍标签：朗读"主机名，副标题"
        .accessibilityLabel("\(host.name)，\(host.subtitle)")
        // 无障碍值：朗读连接状态提示
        .accessibilityValue(dotTip)
    }

    /// 主机右键/长按菜单(与原型 hostMenu 一致)
    /// @ViewBuilder 允许使用多个视图语句构建菜单内容
    @ViewBuilder
    private var hostMenu: some View {
        // 菜单项：打开终端
        Button { callbacks.openTerminal(host) } label: {
            // 终端图标 + 文字
            Label("打开终端", systemImage: "terminal")
        }
        // 菜单项：浏览文件（SFTP）
        Button { callbacks.openSFTP(host) } label: {
            // 文件夹图标
            Label("浏览文件 (SFTP)", systemImage: "folder")
        }
        // 分隔线：在菜单中分隔不同功能组
        Divider()
        // 菜单项：编辑主机配置
        Button { callbacks.editHost(host) } label: {
            // 铅笔图标
            Label("编辑…", systemImage: "pencil")
        }
        // 菜单项：复制主机
        Button { callbacks.copyHost(host) } label: {
            // 复制文档图标
            Label("复制", systemImage: "doc.on.doc")
        }
        // 子菜单：移至分组（可以移动主机到不同分组）
        Menu("移至分组") {
            // 移到根级（不属于任何分组）
            Button("根级（无分组）") { model.moveHost(host.id, toGroup: nil) }
            ForEach(model.groups) { group in
                // 遍历所有分组，每个分组作为一个菜单项
                Button((try? groupPath(groupId: group.id)) ?? group.name) {
                    // 移动到选中的分组
                    model.moveHost(host.id, toGroup: group.id)
                }
            }
        }
        // 分隔线
        Divider()
        // 菜单项：删除主机（红色危险操作）
        Button(role: .destructive) { callbacks.deleteHost(host) } label: {
            // 垃圾桶图标，.destructive 角色使文字显示为红色
            Label("删除主机", systemImage: "trash")
        }
    }
}

/// 分组行:文件夹图标 + 名称;作为 OutlineGroup 的行使用,
/// 展开/折叠三角与缩进由 OutlineGroup 负责,单击选中由 List 负责。
struct GroupRowView: View {
    /// 要显示的分组数据
    let group: HostGroup
    /// 动作回调集合（右键菜单中的操作）
    let callbacks: SidebarCallbacks

    /// 分组行的主体布局：文件夹图标 + 分组名称
    var body: some View {
        // 水平堆叠，元素间距 5pt
        HStack(spacing: 5) {
            // 文件夹图标（SF Symbols 系统图标）
            Image(systemName: "folder")
                // 字体大小：callout（中等偏小）
                .font(.callout)
                // 使用次要前景色（灰色），视觉上不太突出
                .foregroundStyle(.secondary)
            // 分组名称文字
            Text(group.name)
                // 字体：callout 大小 + 半粗体
                .font(.callout.weight(.semibold))
                // 限制为单行，超出显示省略号
                .lineLimit(1)
            // 弹性空间：将内容推到左边
            Spacer(minLength: 0)
        }
        // 垂直内边距 2pt
        .padding(.vertical, 2)
        // 让整个矩形区域可响应手势
        .contentShape(Rectangle())
        // 右键菜单（macOS 右键 / iPadOS 长按）
        .contextMenu { groupMenu }
    }

    /// 分组右键/长按菜单(与原型 groupMenu 一致,另加「在此分组添加主机」)
    @ViewBuilder
    private var groupMenu: some View {
        // 菜单项：在此分组中添加主机
        Button { callbacks.addHostInGroup(group) } label: {
            // 加号图标
            Label("在此分组添加主机…", systemImage: "plus")
        }
        // 分隔线
        Divider()
        // 菜单项：新建子分组
        Button { callbacks.newSubgroup(group) } label: {
            // 文件夹加号图标
            Label("新建子分组", systemImage: "folder.badge.plus")
        }
        // 菜单项：重命名分组
        Button { callbacks.renameGroup(group) } label: {
            // 铅笔图标
            Label("重命名", systemImage: "pencil")
        }
        // 分隔线
        Divider()
        // 菜单项：删除分组（红色危险操作）
        Button(role: .destructive) { callbacks.deleteGroup(group) } label: {
            // 垃圾桶图标，红色文字
            Label("删除分组", systemImage: "trash")
        }
    }
}

/// 传输入口按钮：由本小组件（而非整个侧栏）订阅 TransferStore，
/// 传输期间 5Hz 状态发布只重算角标数字，侧栏树其余部分保持静默。
/// 这种设计避免了传输状态高频更新导致整个侧栏重新渲染的性能问题。
private struct TransferSideEntryButton: View {
    /// 传输数据存储（以 @ObservedObject 订阅，仅本组件会因传输状态变化而刷新）
    @ObservedObject var store: TransferStore
    /// 当前按钮是否处于激活（选中）状态
    let isActive: Bool
    /// 点击按钮时的回调
    let action: () -> Void

    var body: some View {
        // 复用通用的侧栏按钮组件，额外传入活动任务数作为角标
        SideEntryButton(
            title: "任务",
            // 上下箭头图标（表示传输/上传下载）
            systemImage: "arrow.up.arrow.down",
            isActive: isActive,
            // 当前正在进行的传输任务数量（0 则不显示角标）
            badgeCount: store.activeCount,
            action: action
        )
    }
}

/// 侧栏底部固定入口按钮，使用与系统侧栏一致的选中和悬停层级。
/// 视觉效果：选中时背景为主题色半透明，悬停时为灰色半透明，未选中未悬停时透明。
private struct SideEntryButton: View {
    /// 按钮显示文字
    let title: String
    /// SF Symbols 系统图标名称
    let systemImage: String
    /// 是否处于激活（选中）状态（激活时背景色为主题色半透明）
    let isActive: Bool
    /// 角标数字（大于 0 时显示，如传输任务数量）
    var badgeCount: Int = 0
    /// 点击按钮时的回调
    let action: () -> Void
    /// 鼠标是否悬停在按钮上（仅 macOS 有效）
    @State private var hovering = false

    var body: some View {
        // 按钮，点击时执行 action
        Button(action: action) {
            // 水平排列：图标 + 文字 + 弹性空间 + 角标
            HStack(spacing: 8) {
                // SF Symbols 图标
                Image(systemName: systemImage)
                    // 固定图标宽度 16pt，确保所有行图标对齐
                    .frame(width: 16)
                // 按钮文字
                Text(title)
                    // 字体大小：callout
                    .font(.callout)
                // 弹性空间：将角标推到右边
                Spacer()
                if badgeCount > 0 {
                    // 角标：仅在活动任务数 > 0 时显示
                    // 数字文字
                    Text("\(badgeCount)")
                        // 字体：caption + 等宽数字（数字宽度一致，视觉整齐）
                        .font(.caption.monospacedDigit())
                        // 水平内边距 6pt（数字不紧贴胶囊边缘）
                        .padding(.horizontal, 6)
                        // 胶囊形背景，主题色 15% 不透明度
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        // 无障碍标签
                        .accessibilityLabel("\(badgeCount) 个活动任务")
                }
            }
            // 按钮内容水平内边距 8pt
            .padding(.horizontal, 8)
            // 按钮内容垂直内边距 5pt
            .padding(.vertical, 5)
            .background(
                // 背景色根据状态变化：激活 > 悬停 > 默认透明
                isActive ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear),
                // 激活时：主题色 16% 不透明度（蓝色半透明背景）
                // 悬停时：主色 5% 不透明度（非常淡的灰色背景）
                // 默认：透明背景
                // 圆角矩形形状，圆角半径 6pt
                in: RoundedRectangle(cornerRadius: 6)
            )
            // 手势响应区域也是圆角矩形
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        // 使用纯按钮样式（去除系统默认的按钮外观，完全自定义）
        .buttonStyle(.plain)
        #if os(macOS)
        // macOS：监听鼠标悬停事件，更新 hovering 状态以改变背景色
        // $0 为 Bool：true = 鼠标进入，false = 鼠标离开
        .onHover { hovering = $0 }
        #endif
    }
}

// MARK: - 预览

#if DEBUG
// Xcode Preview：在开发时实时预览侧栏外观
#Preview("侧栏") {
    // 导航容器（iPadOS 需要）
    NavigationStack {
        SidebarView()
    }
    // 注入预览用的应用数据模型
    .environmentObject(AppModel.previewModel())
    // 注入预览用的工作区状态
    .environmentObject(WorkspaceStore.previewStore())
    // 注入传输存储（failRule 始终返回 false = 不模拟失败）
    .transferStore(TransferStore(failRule: { _ in false }))
    // 注入消息提示中心
    .environmentObject(ToastCenter())
}
#endif
