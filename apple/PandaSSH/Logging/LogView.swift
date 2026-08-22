import SwiftUI

/// 日志窗口:展示内存缓冲区中的日志条目,按级别着色,
/// 自动滚动到底部,工具栏提供清除按钮。
struct LogView: View {
    @ObservedObject var logger: Logger

    var body: some View {
        Group {
            if logger.entries.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("运行时日志将在此显示")
                )
            } else {
                logList
            }
        }
        .navigationTitle("日志")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    logger.clear()
                } label: {
                    Label("清除", systemImage: "trash")
                }
                .disabled(logger.entries.isEmpty)
            }
        }
    }

    /// 日志列表:每行显示 formatted 文本 + 级别颜色标记。
    private var logList: some View {
        ScrollViewReader { proxy in
            List(logger.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(entry.level.color)
                        .frame(width: 6, height: 6)
                    Text(entry.formatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: logger.entries.last?.id) { _, lastID in
                if let lastID {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastID = logger.entries.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

#if DEBUG
#Preview("日志窗口") {
    LogView(logger: previewLogger())
}

private func previewLogger() -> Logger {
    let logger = Logger(configDirectory: nil)
    logger.info("应用启动", module: LogModule.config)
    logger.info("已连接 host=192.168.1.1:22", module: "SSH")
    logger.warning("主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…", module: "HostKey")
    logger.error("连接失败 host=192.168.1.1:22; 原因=认证失败", module: "SSH")
    logger.debug("FFI 调用入口: list_hosts", module: "FFI")
    return logger
}
#endif
