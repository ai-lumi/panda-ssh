import SwiftUI

/// 传输任务面板(SFTP 标签右侧可开合):方向图标、文件名、源→目标、
/// 进度条 + 百分比 + 字节数、六态徽标与操作按钮;最新任务在最上(与原型一致)。
/// 任务组可展开/折叠,展示组级进度与批量控制;组内文件任务支持单独控制。
struct TransferPanelView: View {
    @ObservedObject var store: TransferStore
    @State private var expandedGroups: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.tasks.isEmpty {
                ContentUnavailableView(
                    "暂无传输任务",
                    systemImage: "arrow.up.arrow.down",
                    description: Text("选中文件后点击「上传 →」或「← 下载」")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.taskGroups) { group in
                        GroupRow(
                            group: group,
                            store: store,
                            isExpanded: expandedGroups.contains(group.id)
                        ) {
                            if expandedGroups.contains(group.id) {
                                expandedGroups.remove(group.id)
                            } else {
                                expandedGroups.insert(group.id)
                            }
                        }
                    }
                    ForEach(store.tasks.filter { $0.groupID == nil }.reversed()) { task in
                        TransferRow(task: task, store: store)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("传输任务")
                .font(.callout.bold())
            Spacer()
            Button("清除已完成") { store.clearFinished() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 任务组行:组名、总进度、批量控制;展开后列出组内文件任务。
private struct GroupRow: View {
    let group: TransferGroup
    @ObservedObject var store: TransferStore
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: group.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(group.direction == .upload ? Color.accentColor : Color.green)
                Image(systemName: isExpanded ? "folder.open" : "folder")
                    .foregroundStyle(Color.blue)
                Text(group.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(status: group.status)
            }
            ProgressView(value: group.progress)
                .progressViewStyle(.linear)
                .tint(barColor)
            HStack(spacing: 8) {
                Text("\(Int(group.progress * 100))%")
                Text("\(formatBytes(group.transferred)) / \(formatBytes(group.totalSize))")
                Spacer()
                groupOperations
                Button {
                    toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(group.tasks) { task in
                        TransferRow(task: task, store: store, indented: true)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var barColor: Color {
        switch group.status {
        case .done: .green
        case .failed: .red
        default: .accentColor
        }
    }

    @ViewBuilder
    private var groupOperations: some View {
        switch group.status {
        case .running, .queued:
            HStack(spacing: 8) {
                Button("暂停") { store.pauseGroup(id: group.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("取消") { store.cancelGroup(id: group.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .paused:
            HStack(spacing: 8) {
                Button("继续") { store.resumeGroup(id: group.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("取消") { store.cancelGroup(id: group.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .failed:
            Button("重试") { store.retryGroup(id: group.id) }
                .buttonStyle(.borderless)
                .font(.caption)
        case .done, .cancelled:
            EmptyView()
        }
    }
}

/// 单个传输任务行。
private struct TransferRow: View {
    let task: TransferTask
    @ObservedObject var store: TransferStore
    var indented: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: task.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(task.direction == .upload ? Color.accentColor : Color.green)
                Text(task.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(status: task.status)
            }
            Text(subtitle)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = task.error, task.status == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            conflictNotice
            progressBar
            HStack(spacing: 8) {
                Text("\(task.percent)%")
                Text("\(formatBytes(task.transferred)) / \(formatBytes(task.size))")
                Spacer()
                operations
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            if task.status == .running {
                speedInfo
            }
        }
        .padding(.horizontal, indented ? 8 : 10)
        .padding(.vertical, indented ? 5 : 8)
    }

    /// 批量任务等待覆盖确认时的提示行。
    @ViewBuilder
    private var conflictNotice: some View {
        if let conflict = task.pendingConflict {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.orange)
                Text("“\(conflict.name)” 已存在，等待覆盖确认")
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.top, 2)
        }
    }

    /// 原生线性进度条:完成绿色、失败红色,其余强调色。
    private var progressBar: some View {
        ProgressView(value: task.progress)
            .progressViewStyle(.linear)
            .tint(barColor)
            .animation(.linear(duration: 0.12), value: task.transferred)
    }

    /// 实时速度、总速度与剩余时间。
    private var speedInfo: some View {
        HStack(spacing: 8) {
            Text("\(formatSpeed(task.liveSpeed))")
            Text("(") + Text("均速 \(formatSpeed(task.totalSpeed))") + Text(")")
            if let remaining = task.estimatedTimeRemaining {
                Spacer()
                Text("剩余 \(formatDuration(remaining))")
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        if task.isBatch {
            let count = task.batchSources.count
            let label = count > 0 ? "\(count) 项" : "批量任务"
            return "\(label) → \(task.batchDestDir)"
        }
        return "\(task.source) → \(task.destination)"
    }

    private var barColor: Color {
        switch task.status {
        case .done: .green
        case .failed: .red
        default: .accentColor
        }
    }

    @ViewBuilder
    private var operations: some View {
        switch task.status {
        case .running, .queued:
            if task.isBatch {
                Button("取消") { store.cancel(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                HStack(spacing: 8) {
                    Button("暂停") { store.pause(id: task.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button("取消") { store.cancel(id: task.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        case .paused:
            HStack(spacing: 8) {
                Button("继续") { store.resume(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("取消") { store.cancel(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .failed:
            if task.isBatch {
                EmptyView()
            } else {
                Button("重试") { store.retry(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .done, .cancelled:
            EmptyView()
        }
    }
}

/// 六态徽标(配色与原型 .st.* 一致)。
private struct StatusBadge: View {
    let status: TransferStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch status {
        case .queued: Color.secondary.opacity(0.25)
        case .running: Color.accentColor.opacity(0.15)
        case .paused: Color.orange.opacity(0.15)
        case .done: Color.green.opacity(0.16)
        case .failed: Color.red.opacity(0.14)
        case .cancelled: Color.secondary.opacity(0.2)
        }
    }

    private var foreground: Color {
        switch status {
        case .queued: .secondary
        case .running: .accentColor
        case .paused: .orange
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

#if DEBUG
#Preview("传输面板") {
    let store = TransferStore()
    store.add(direction: .upload, name: "deploy.tar.gz", size: 18_432_000,
              source: "/Users/luowenqiang/deploy.tar.gz", destination: "/home/deploy/deploy.tar.gz")
    store.add(direction: .download, name: "app.log", size: 10_485_760,
              source: "/home/deploy/logs/app.log", destination: "/Users/luowenqiang/app.log")
    store.tick(seconds: 2)
    return TransferPanelView(store: store)
}
#endif
