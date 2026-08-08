import SwiftUI

/// 代码片段页:左侧列表 + 右侧详情(等宽代码块 + 复制),
/// 支持新建/编辑/删除;数据持久化到 Rust FFI 管理的 Markdown 文件。
struct SnippetsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var toast: ToastCenter

    @State private var selection: String?
    @State private var editing: EditingTarget?
    @State private var pendingDelete: Snippet?

    private enum EditingTarget: Identifiable {
        case new
        case edit(Snippet)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let snippet): snippet.id
            }
        }
    }

    private var current: Snippet? {
        model.snippets.first { $0.id == selection } ?? model.snippets.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list
                Divider()
                detail
            }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                SnippetEditSheet(snippet: nil) { snippet in
                    selection = model.saveSnippet(snippet).id
                    toast.show("片段已保存")
                }
            case .edit(let snippet):
                SnippetEditSheet(snippet: snippet) { updated in
                    model.saveSnippet(updated)
                    toast.show("片段已保存")
                }
            }
        }
        .alert("删除片段", isPresented: hasPendingDelete, presenting: pendingDelete) { snippet in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                model.deleteSnippet(id: snippet.id)
                if selection == snippet.id { selection = nil }
                toast.show("片段已删除")
            }
        } message: { snippet in
            Text("确定删除片段「\(snippet.title)」吗？")
        }
    }

    private var hasPendingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Text("代码片段")
                .font(.title3).bold()
            Spacer()
            Button("＋ 新建片段") { editing = .new }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if model.snippets.isEmpty {
                    Text("暂无片段")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                }
                ForEach(model.snippets) { snippet in
                    Button {
                        selection = snippet.id
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snippet.title)
                                .font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 4) {
                                ForEach(snippet.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(snippet.summary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            (selection ?? model.snippets.first?.id) == snippet.id
                                ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 280)
    }

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let snippet = current {
            VStack(alignment: .leading, spacing: 10) {
                Text(snippet.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    ForEach(snippet.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snippet.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(snippet.code)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.12, green: 0.12, blue: 0.14), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    Button("复制") {
                        copyToPasteboard(snippet.code)
                        toast.show("已复制")
                    }
                    Button("编辑") { editing = .edit(snippet) }
                    Button("删除", role: .destructive) { pendingDelete = snippet }
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("选择或新建一个片段", systemImage: "chevron.left.forwardslash.chevron.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// 新建/编辑片段表单:标题、标签(逗号分隔)、说明、代码。
/// 标题与代码必填,否则保存禁用(与原型一致)。
struct SnippetEditSheet: View {
    /// 待编辑片段;nil 表示新建
    let snippet: Snippet?
    var onSave: (Snippet) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var tags = ""
    @State private var summary = ""
    @State private var code = ""

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("标签", text: $tags, prompt: Text("逗号分隔，如：运维, 日志"))
                TextField("说明", text: $summary)
                Section("代码") {
                    TextEditor(text: $code)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(snippet == nil ? "新建片段" : "编辑片段")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            guard let snippet else { return }
            title = snippet.title
            tags = snippet.tags.joined(separator: ", ")
            summary = snippet.summary
            code = snippet.code
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private func save() {
        // 中英文逗号都可作分隔符
        let parsedTags = tags
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(Snippet(
            id: snippet?.id ?? "s-\(UUID().uuidString)",
            title: title.trimmingCharacters(in: .whitespaces),
            tags: parsedTags,
            summary: summary.trimmingCharacters(in: .whitespaces),
            code: code
        ))
        dismiss()
    }
}

#if DEBUG
#Preview("代码片段") {
    SnippetsView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(ToastCenter())
}

#Preview("新建片段") {
    SnippetEditSheet(snippet: nil)
}
#endif
