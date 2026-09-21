// ============================================================================
// SnippetsView.swift — 代码片段管理视图
//
// 本文件提供代码片段的浏览、新建、编辑、删除功能。
// 界面布局：
//   - 顶部：标题栏（"代码片段" + 新建按钮）
//   - 左侧：片段列表（280pt 宽），显示标题、标签、摘要
//   - 右侧：片段详情，显示完整代码（等宽字体）+ 复制/编辑/删除按钮
//
// 数据持久化：片段以 Markdown 文件形式存储在 Rust FFI 管理的目录中，
// 通过 AppModel 提供的方法进行增删改查。
//
// 包含两个视图：
//   1. SnippetsView：主视图，展示片段列表和详情
//   2. SnippetEditSheet：新建/编辑片段的表单弹窗
// ============================================================================

// 导入 SwiftUI 框架
import SwiftUI

/// 代码片段页:左侧列表 + 右侧详情(等宽代码块 + 复制),
/// 支持新建/编辑/删除;数据持久化到 Rust FFI 管理的 Markdown 文件。
struct SnippetsView: View {
    // ---- 环境对象 ----
    // 全局数据模型，管理片段列表和后端操作
    @EnvironmentObject private var model: AppModel
    // 轻提示中心，用于显示"已保存""已删除"等短暂提示
    @EnvironmentObject private var toast: ToastCenter

    // ---- 视图状态 ----
    // 当前选中的片段 ID，nil 表示未选中
    @State private var selection: String?
    // 控制编辑弹窗的显示状态和编辑目标
    @State private var editing: EditingTarget?
    // 待删除的片段，非 nil 时弹出确认对话框
    @State private var pendingDelete: Snippet?

    // ---- 编辑目标枚举 ----
    // 用枚举区分两种编辑场景：新建 或 编辑已有片段
    private enum EditingTarget: Identifiable {
        // 新建片段
        case new
        // 编辑已有片段，关联该片段数据
        case edit(Snippet)
        // Identifiable 协议要求，用于 .sheet(item:) 识别
        var id: String {
            switch self {
            // 新建场景的固定 ID
            case .new: "new"
            // 编辑场景使用片段的 ID
            case .edit(let snippet): snippet.id
            }
        }
    }

    // ---- 计算属性：当前显示的片段 ----
    // 优先显示选中的片段；如果未选中，则显示列表中的第一个片段
    private var current: Snippet? {
        // 找不到选中项则回退到第一项
        model.snippets.first { $0.id == selection } ?? model.snippets.first
    }

    // ---- 主视图体 ----
    var body: some View {
        // VStack：垂直堆叠，从上到下排列：头部 → 分隔线 → 水平内容区
        // spacing: 0 表示各部分之间无额外间距，由内边距控制
        VStack(spacing: 0) {
            // 顶部标题栏
            header
            // 水平分隔线，视觉分割头部和内容区
            Divider()
            // 水平堆叠：左侧列表 → 分隔线 → 右侧详情
            HStack(spacing: 0) {
                // 左侧片段列表
                list
                // 垂直分隔线，分割列表和详情
                Divider()
                // 右侧片段详情
                detail
            }
        }
        // .sheet(item:)：当 editing 非 nil 时弹出编辑表单
        // item 绑定到 editing，值变化时自动显示/隐藏弹窗
        .sheet(item: $editing) { target in
            switch target {
            // 新建片段场景
            case .new:
                // snippet: nil 表示新建模式
                SnippetEditSheet(snippet: nil) { snippet in
                    // 保存后选中新建的片段
                    selection = model.saveSnippet(snippet).id
                    // 显示轻提示
                    toast.show("片段已保存")
                }
            // 编辑已有片段场景
            case .edit(let snippet):
                // 传入原片段数据
                SnippetEditSheet(snippet: snippet) { updated in
                    // 保存更新后的片段
                    model.saveSnippet(updated)
                    // 显示轻提示
                    toast.show("片段已保存")
                }
            }
        }
        // 删除确认对话框
        // hasPendingDelete 控制显示，presenting 传递数据
        .alert("删除片段", isPresented: hasPendingDelete, presenting: pendingDelete) { snippet in
            // 取消按钮，关闭对话框不删除
            Button("取消", role: .cancel) {}
            // destructive 红色按钮，表示危险操作
            Button("删除", role: .destructive) {
                // 调用 model 删除片段
                model.deleteSnippet(id: snippet.id)
                // 如果删除的是当前选中的片段，清空选中状态
                if selection == snippet.id { selection = nil }
                // 显示轻提示
                toast.show("片段已删除")
            }
        // message 闭包提供对话框的说明文字
        } message: { snippet in
            // 显示片段标题，让用户确认删除对象
            Text("确定删除片段「\(snippet.title)」吗？")
        }
    }

    // ---- 计算属性：删除对话框的显示状态绑定 ----
    // 将 pendingDelete 是否为 nil 转换为 Bool 绑定，供 .alert 的 isPresented 使用
    private var hasPendingDelete: Binding<Bool> {
        // get: 有待删除项则显示；set: 关闭时清空
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: 头部

    // ---- 顶部标题栏 ----
    private var header: some View {
        // 水平排列，元素间距 10pt
        HStack(spacing: 10) {
            // 标题文字
            Text("代码片段")
                // 字体：title3 级别（中等大小），加粗
                .font(.title3).bold()
            // 弹性空间，将后续元素推到右侧
            Spacer()
            // 点击后将 editing 设为 .new，触发新建弹窗
            Button("＋ 新建片段") { editing = .new }
                // 按钮尺寸：小号，适合放在工具栏/标题栏
                .controlSize(.small)
        }
        // 水平内边距：左右各 20pt
        .padding(.horizontal, 20)
        // 垂直内边距：上下各 10pt
        .padding(.vertical, 10)
    }

    // MARK: 列表

    // ---- 左侧片段列表 ----
    private var list: some View {
        // Group 用于条件分支：空状态 或 列表
        Group {
            // 如果没有片段
            if model.snippets.isEmpty {
                // ContentUnavailableView：系统提供的空状态视图，显示图标和提示文字
                // 显示代码图标和提示
                ContentUnavailableView("暂无片段", systemImage: "chevron.left.forwardslash.chevron.right")
                    // 填满整个左侧区域
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 有片段时显示列表
            } else {
                // List：系统列表组件，$selection 绑定选中项 ID
                List(selection: $selection) {
                    // 遍历所有片段
                    ForEach(model.snippets) { snippet in
                        // 垂直排列，左对齐，间距 3pt
                        VStack(alignment: .leading, spacing: 3) {
                            // 片段标题
                            Text(snippet.title)
                                // 字体：callout 级别，半粗体
                                .font(.callout.weight(.semibold))
                            // 水平排列标签，间距 4pt
                            HStack(spacing: 4) {
                                // 遍历标签数组
                                ForEach(snippet.tags, id: \.self) { tag in
                                    // 标签文字
                                    Text(tag)
                                        // 字体：caption2 级别（很小）
                                        .font(.caption2)
                                        // 水平内边距：左右各 6pt
                                        .padding(.horizontal, 6)
                                        // 垂直内边距：上下各 1pt
                                        .padding(.vertical, 1)
                                        // 背景：半透明材质，胶囊形状
                                        .background(.regularMaterial, in: Capsule())
                                        // 文字颜色：次要色（灰色）
                                        .foregroundStyle(.secondary)
                                }
                            }
                            // 片段摘要
                            Text(snippet.summary)
                                // 字体：caption 级别（小号）
                                .font(.caption)
                                // 文字颜色：次要色（灰色）
                                .foregroundStyle(.secondary)
                                // 限制为 1 行，超出部分省略
                                .lineLimit(1)
                        }
                        // tag 标识该行对应的片段 ID，用于 $selection 绑定
                        .tag(snippet.id)
                    }
                }
                // 列表样式：sidebar（侧边栏风格，macOS 特有）
                .listStyle(.sidebar)
            }
        }
        // 固定宽度：280pt
        .frame(width: 280)
    }

    // MARK: 详情

    // ---- 右侧片段详情 ----
    // @ViewBuilder 允许使用 if/else 条件分支构建视图
    @ViewBuilder
    private var detail: some View {
        // 如果有当前片段
        if let snippet = current {
            // 垂直排列，左对齐，间距 10pt
            VStack(alignment: .leading, spacing: 10) {
                // 片段标题
                Text(snippet.title)
                    // 字体：headline 级别（标题）
                    .font(.headline)
                // 水平排列标签，间距 6pt
                HStack(spacing: 6) {
                    // 遍历标签
                    ForEach(snippet.tags, id: \.self) { tag in
                        // 标签文字
                        Text(tag)
                            // 字体：caption2 级别
                            .font(.caption2)
                            // 水平内边距：左右各 8pt
                            .padding(.horizontal, 8)
                            // 垂直内边距：上下各 2pt
                            .padding(.vertical, 2)
                            // 背景：半透明材质，胶囊形状
                            .background(.regularMaterial, in: Capsule())
                            // 文字颜色：次要色
                            .foregroundStyle(.secondary)
                    }
                }
                // 片段摘要
                Text(snippet.summary)
                    // 字体：caption 级别
                    .font(.caption)
                    // 文字颜色：次要色
                    .foregroundStyle(.secondary)
                // ScrollView：可滚动容器，用于显示可能很长的代码
                // 水平滚动，隐藏滚动条
                ScrollView(.horizontal, showsIndicators: false) {
                    // 代码内容
                    Text(snippet.code)
                        // 字体：callout 级别，等宽字体（代码专用）
                        .font(.system(.callout, design: .monospaced))
                        // 文字颜色：主要色（黑色/白色）
                        .foregroundStyle(.primary)
                        // 允许用户选中和复制文本
                        .textSelection(.enabled)
                        // 内边距：四周各 12pt
                        .padding(12)
                }
                // 宽度填满，左对齐
                .frame(maxWidth: .infinity, alignment: .leading)
                // 背景：半透明材质，圆角矩形（半径 8pt）
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                // 水平排列操作按钮，间距 10pt
                HStack(spacing: 10) {
                    // 复制按钮
                    Button("复制") {
                        // 调用方法将代码复制到系统剪贴板
                        copyToPasteboard(snippet.code)
                        // 显示轻提示
                        toast.show("已复制")
                    }
                    // 编辑按钮：打开编辑弹窗
                    Button("编辑") { editing = .edit(snippet) }
                    // 删除按钮：设置待删除项，触发确认对话框
                    Button("删除", role: .destructive) { pendingDelete = snippet }
                }
                // 按钮尺寸：小号
                .controlSize(.small)
                // 弹性空间，将上方内容推到顶部
                Spacer()
            }
            // 内边距：上 16、左 20、下 16、右 20
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
            // 填满区域，左上对齐
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 没有片段时显示空状态
        } else {
            // 提示用户选择或新建
            ContentUnavailableView("选择或新建一个片段", systemImage: "chevron.left.forwardslash.chevron.right")
                // 填满整个右侧区域
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ---- 复制到剪贴板 ----
    // 根据平台调用不同的系统 API
    private func copyToPasteboard(_ text: String) {
        // macOS 平台
        #if os(macOS)
        // 清空剪贴板
        NSPasteboard.general.clearContents()
        // 写入文本
        NSPasteboard.general.setString(text, forType: .string)
        // iOS/iPadOS 平台
        #else
        // 直接设置剪贴板文本
        UIPasteboard.general.string = text
        #endif
    }
}

// ============================================================================
// SnippetEditSheet — 新建/编辑片段表单
// ============================================================================

/// 新建/编辑片段表单:标题、标签(逗号分隔)、说明、代码。
/// 标题与代码必填,否则保存禁用(与原型一致)。
struct SnippetEditSheet: View {
    /// 待编辑片段;nil 表示新建
    // 编辑模式传入原片段；新建模式传 nil
    let snippet: Snippet?
    // 保存回调，接收更新后的片段
    var onSave: (Snippet) -> Void = { _ in }
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss

    // ---- 表单状态 ----
    // 片段标题
    @State private var title = ""
    // 标签（逗号分隔的字符串）
    @State private var tags = ""
    // 摘要说明
    @State private var summary = ""
    // 代码内容
    @State private var code = ""

    // ---- 计算属性：是否可以保存 ----
    // 标题和代码都不为空时才能保存
    private var canSave: Bool {
        // 标题不为空
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            // 代码不为空（包括换行符）
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // 导航容器，提供标题栏和工具栏
        NavigationStack {
            // 表单布局
            Form {
                // 标题输入框
                TextField("标题", text: $title)
                // 标签输入框，提示格式
                TextField("标签", text: $tags, prompt: Text("逗号分隔，如：运维, 日志"))
                // 摘要输入框
                TextField("说明", text: $summary)
                // 代码分区
                Section("代码") {
                    // TextEditor：多行文本编辑器，适合输入代码
                    TextEditor(text: $code)
                        // 字体：等宽字体
                        .font(.system(.callout, design: .monospaced))
                        // 最小高度：120pt
                        .frame(minHeight: 120)
                }
            }
            // 导航栏标题
            .navigationTitle(snippet == nil ? "新建片段" : "编辑片段")
            // 工具栏按钮
            .toolbar {
                // 取消按钮位置
                ToolbarItem(placement: .cancellationAction) {
                    // 点击关闭弹窗
                    Button("取消") { dismiss() }
                }
                // 保存按钮位置
                ToolbarItem(placement: .confirmationAction) {
                    // 点击调用 save()
                    Button("保存") { save() }
                        // 必填字段为空时禁用
                        .disabled(!canSave)
                }
            }
        }
        // 视图出现时加载数据
        .onAppear {
            // 新建模式无需加载
            guard let snippet else { return }
            // 填充标题
            title = snippet.title
            // 将标签数组转为逗号分隔字符串
            tags = snippet.tags.joined(separator: ", ")
            // 填充摘要
            summary = snippet.summary
            // 填充代码
            code = snippet.code
        }
        // macOS 平台
        #if os(macOS)
        // 窗口最小尺寸
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    // ---- 保存方法 ----
    private func save() {
        // 中英文逗号都可作分隔符
        let parsedTags = tags
            // 按中英文逗号分割
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            // 去除每个标签的首尾空格
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // 过滤空标签
            .filter { !$0.isEmpty }
        // 构造片段对象并调用回调
        onSave(Snippet(
            // 编辑时保留 ID；新建时生成新 ID
            id: snippet?.id ?? "s-\(UUID().uuidString)",
            // 去除标题首尾空格
            title: title.trimmingCharacters(in: .whitespaces),
            // 解析后的标签数组
            tags: parsedTags,
            // 去除摘要首尾空格
            summary: summary.trimmingCharacters(in: .whitespaces),
            // 代码内容保持原样
            code: code
        ))
        // 关闭弹窗
        dismiss()
    }
}

// ---- Xcode 预览配置 ----
// 仅在 Debug 模式下注册预览
#if DEBUG
// 预览场景：主视图
#Preview("代码片段") {
    SnippetsView()
        // 注入预览数据模型
        .environmentObject(AppModel.previewModel())
        // 注入轻提示中心
        .environmentObject(ToastCenter())
}

// 预览场景：新建片段表单
#Preview("新建片段") {
    // snippet: nil 表示新建模式
    SnippetEditSheet(snippet: nil)
}
#endif
