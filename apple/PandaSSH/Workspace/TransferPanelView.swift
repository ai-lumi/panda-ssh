import SwiftUI

/// 全局传输页面只观察应用共享队列；关闭页面不会影响任务生命周期。
struct TransferPageView: View {
    @ObservedObject var store: TransferStore
    @State private var expandedGroups: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("传输任务")
                    .font(.title2.bold())
                Text("\(store.activeCount) 个活动任务 · 共 \(store.tasks.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("清除已完成") { store.clearFinished() }
                .buttonStyle(.bordered)
        }
        .padding(16)
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
    @EnvironmentObject private var model: AppModel
    @State private var showsPaths = false
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    endpoint(title: "源", name: presentation.sourceEndpoint, path: presentation.sourcePath)
                        .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    endpoint(title: "目标", name: presentation.destinationEndpoint, path: presentation.destinationPath)
                        .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    endpoint(title: "源", name: presentation.sourceEndpoint, path: presentation.sourcePath)
                    endpoint(title: "目标", name: presentation.destinationEndpoint, path: presentation.destinationPath)
                }
            }
            Button(showsPaths ? "收起完整路径" : "查看完整路径") { showsPaths.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)
            if let error = task.error, task.status == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            conflictNotice
            progressBar
            HStack(spacing: 8) {
                Text(presentation.progress.map { "\(Int($0 * 100))%" } ?? "—")
                Text("\(formatBytes(task.transferred)) / \(formatBytes(task.size))")
                Spacer()
                operations
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            speedInfo
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
        ProgressView(value: presentation.progress)
            .progressViewStyle(.linear)
            .tint(barColor)
            .animation(.linear(duration: 0.12), value: task.transferred)
    }

    /// 实时速度、总速度与剩余时间。
    private var speedInfo: some View {
        HStack(spacing: 8) {
            Text("速度 \(formatSpeed(presentation.liveSpeed))")
            Text("(") + Text("均速 \(formatSpeed(task.totalSpeed))") + Text(")")
            if task.status == .running, let remaining = task.estimatedTimeRemaining {
                Spacer()
                Text("剩余 \(formatDuration(remaining))")
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var presentation: TransferTaskPresentation {
        TransferTaskPresentation(
            task: task,
            hostName: model.hosts.first(where: { $0.id == task.hostID })?.name
        )
    }

    private func endpoint(title: String, name: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)：\(name)")
                .font(.caption.weight(.semibold))
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(showsPaths ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
                .accessibilityLabel("\(title)路径：\(path)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
#Preview("全局传输任务") {
    let store = TransferStore(failRule: { _ in false })
    store.add(direction: .upload, name: "deploy.tar.gz", size: 18_432_000,
              source: "/Users/luowenqiang/deploy.tar.gz", destination: "/home/deploy/deploy.tar.gz")
    store.add(direction: .download, name: "app.log", size: 10_485_760,
              source: "/home/deploy/logs/app.log", destination: "/Users/luowenqiang/app.log")
    store.tick(seconds: 2)
    return TransferPageView(store: store)
        .environmentObject(AppModel.previewModel())
}
#endif

/// 仅负责端点标签和未知进度的展示，不改变任务记录或传输规则。
struct TransferTaskPresentation {
    let sourceEndpoint: String
    let destinationEndpoint: String
    let sourcePath: String
    let destinationPath: String
    let progress: Double?
    let liveSpeed: Int64

    init(task: TransferTask, hostName: String?) {
        let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (task.hostID.isEmpty ? "未知主机" : task.hostID)
        sourceEndpoint = task.direction == .upload ? "本地" : remote
        destinationEndpoint = task.direction == .upload ? remote : "本地"
        sourcePath = task.isBatch && !task.batchSources.isEmpty
            ? task.batchSources.joined(separator: "\n") : task.source
        destinationPath = task.isBatch ? task.batchDestDir : task.destination
        progress = task.size == 0 && task.status != .done ? nil : task.progress
        liveSpeed = task.status == .running ? max(0, task.liveSpeed) : 0
    }
}
