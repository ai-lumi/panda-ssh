import SwiftUI

/// 传输任务面板(SFTP 标签右侧可开合):方向图标、文件名、源→目标、
/// 进度条 + 百分比 + 字节数、五态徽标与操作按钮;最新任务在最上(与原型一致)。
struct TransferPanelView: View {
    @ObservedObject var store: TransferStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.tasks.isEmpty {
                Text("暂无传输任务\n选中文件后点击「上传 →」或「← 下载」")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.tasks.reversed()) { task in
                            TransferRow(task: task, store: store)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 340)
        .background(Color.cardBackground)
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

/// 单个传输任务行。
private struct TransferRow: View {
    let task: TransferTask
    @ObservedObject var store: TransferStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: task.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(task.direction == .upload ? Color.accentColor : Color.green)
                Text(task.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(status: task.status)
            }
            Text("\(task.source) → \(task.destination)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = task.error, task.status == .failed {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            progressBar
            HStack(spacing: 8) {
                Text("\(task.percent)%")
                Text("\(formatBytes(task.transferred)) / \(formatBytes(task.size))")
                Spacer()
                operations
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    /// 原生线性进度条:完成绿色、失败红色,其余强调色。
    private var progressBar: some View {
        ProgressView(value: task.progress)
            .progressViewStyle(.linear)
            .tint(barColor)
            .animation(.linear(duration: 0.12), value: task.transferred)
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
            Button("取消") { store.cancel(id: task.id) }
                .buttonStyle(.borderless)
                .font(.caption)
        case .failed:
            Button("重试") { store.retry(id: task.id) }
                .buttonStyle(.borderless)
                .font(.caption)
        case .done, .cancelled:
            EmptyView()
        }
    }
}

/// 五态徽标(配色与原型 .st.* 一致)。
private struct StatusBadge: View {
    let status: TransferStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch status {
        case .queued: Color(white: 0.68).opacity(0.25)
        case .running: Color.accentColor.opacity(0.15)
        case .done: Color.green.opacity(0.16)
        case .failed: Color.red.opacity(0.14)
        case .cancelled: Color(white: 0.56).opacity(0.2)
        }
    }

    private var foreground: Color {
        switch status {
        case .queued: Color(red: 0.43, green: 0.43, blue: 0.45)
        case .running: .accentColor
        case .done: Color(red: 0.12, green: 0.54, blue: 0.23)
        case .failed: Color(red: 0.84, green: 0, blue: 0.08)
        case .cancelled: Color(red: 0.39, green: 0.39, blue: 0.4)
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
