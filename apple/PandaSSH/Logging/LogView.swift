// =============================================================================
// LogView.swift — 日志查看窗口
// =============================================================================
// 本文件实现了应用内的日志查看界面。
// 功能：
//   - 展示内存缓冲区中的日志条目列表
//   - 每条日志左侧有彩色圆点标记日志级别（info/warning/error/debug）
//   - 日志文本使用等宽字体显示，便于阅读技术信息
//   - 新日志出现时自动滚动到底部（最新位置）
//   - 空状态时显示"暂无日志"占位视图
//   - 工具栏提供"清除"按钮，可一键清空所有日志
// =============================================================================

// 引入 SwiftUI 框架，提供声明式 UI 能力
import SwiftUI

/// 日志窗口:展示内存缓冲区中的日志条目,按级别着色,
/// 自动滚动到底部,工具栏提供清除按钮。
///
/// 视觉效果：一个列表视图，每行是一条日志，左侧有彩色小圆点，
/// 右侧是等宽字体的日志文本。无日志时显示居中的空状态图标+文字。
struct LogView: View {
    /// 日志数据源：Logger 实例，持有日志条目数组。
    /// @ObservedObject 使得当日志条目变化时视图自动刷新。
    @ObservedObject var logger: Logger

    /// 定义视图的主体结构：根据日志是否为空，显示不同的内容。
    var body: some View {
        // Group 将条件分支的两个视图统一为同一类型，满足 some View 要求
        Group {
            // 判断日志条目数组是否为空
            if logger.entries.isEmpty {
                // 系统提供的空状态占位视图（iOS 17+/macOS 14+）
                ContentUnavailableView(
                    // 主标题文字
                    "暂无日志",
                    // 系统图标：文档+放大镜，表示"没有可搜索的内容"
                    systemImage: "doc.text.magnifyingglass",
                    // 副标题描述文字，告知用户此处用途
                    description: Text("运行时日志将在此显示")
                )
            // 有日志条目时，显示日志列表
            } else {
                // 引用下方定义的私有计算属性 logList
                logList
            }
        }
        // 导航栏标题：显示"日志"（macOS 窗口标题 / iOS 导航栏标题）
        .navigationTitle("日志")
        // 工具栏配置：在导航栏/窗口工具栏中添加按钮
        .toolbar {
            // 工具栏项位置：主要操作区域（macOS 右上角 / iOS 导航栏右侧）
            ToolbarItem(placement: .primaryAction) {
                // 按钮，role: .destructive 表示破坏性操作，文字自动显示为红色
                Button(role: .destructive) {
                    // 点击时调用 logger 的 clear() 方法，清空所有日志条目
                    logger.clear()
                } label: {
                    // 按钮标签：文字"清除" + 垃圾桶图标 🗑️
                    Label("清除", systemImage: "trash")
                }
                // 当日志为空时禁用按钮（灰色不可点击），避免无意义的清除操作
                .disabled(logger.entries.isEmpty)
            }
        }
    }

    /// 日志列表:每行显示 formatted 文本 + 级别颜色标记。
    ///
    /// 视觉效果：一个可滚动的列表，每行左侧有一个 6pt 的彩色圆点（颜色对应日志级别），
    /// 右侧是等宽字体的格式化日志文本。debug 级别日志使用次要文字颜色（更淡）。
    /// 新日志追加时自动带动画滚动到最底部。
    private var logList: some View {
        // ScrollViewReader 提供编程式滚动能力，通过 proxy 可以滚动到指定 id 的行
        ScrollViewReader { proxy in
            // List 遍历日志条目数组，每个条目渲染一行；Identifiable 协议提供行的 id
            List(logger.entries) { entry in
                // 水平堆叠：圆点 + 文字，按首行文字基线对齐，间距 6pt
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 绘制一个圆形
                    Circle()
                        // 填充颜色：由日志级别决定（如 error=红色, warning=橙色, info=蓝色, debug=灰色）
                        .fill(entry.level.color)
                        // 设置圆形尺寸为 6x6 pt，作为小圆点标记
                        .frame(width: 6, height: 6)
                    // 显示格式化后的日志文本（包含时间戳、模块名、消息内容等）
                    Text(entry.formatted)
                        // 字体：caption 字号 + 等宽字体设计（每个字符宽度相同，便于对齐技术文本）
                        .font(.system(.caption, design: .monospaced))
                        // 文字颜色：debug 级别用次要色（更淡/灰色），其他级别用主要色（正常黑色/白色）
                        .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                        // 允许用户选中并复制日志文本（macOS 上可拖选文字）
                        .textSelection(.enabled)
                        // 固定垂直尺寸：允许文字换行时纵向扩展，不被截断；水平方向保持自适应宽度
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 为每行设置唯一 id，供 ScrollViewReader 的 proxy.scrollTo() 定位使用
                .id(entry.id)
            }
            // 列表样式：plain（无分组背景、无行分隔符，简洁风格）
            .listStyle(.plain)
            // 监听最后一条日志的 id 变化（即有新日志追加时触发）
            .onChange(of: logger.entries.last?.id) { _, lastID in
                // 如果成功解包 lastID（有新日志）
                if let lastID {
                    // 带动画地执行滚动
                    withAnimation {
                        // 滚动到最新日志行，anchor: .bottom 将该行定位在可视区域底部
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            // 视图首次出现时执行（页面刚打开时）
            .onAppear {
                // 获取最后一条日志的 id
                if let lastID = logger.entries.last?.id {
                    // 立即滚动到底部，确保打开时显示最新日志（无动画，瞬间定位）
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

// =============================================================================
// Preview 预览代码（仅 DEBUG 模式）
// =============================================================================
// 以下代码仅在 Debug 构建时编译，用于 Xcode Preview 画布中实时预览 LogView 的效果。
// Release 构建不包含这些代码，不影响最终发布包体积。
// =============================================================================

// 条件编译：仅 Debug 模式下编译以下预览代码
#if DEBUG
// Xcode Preview 声明：在预览画布中展示 LogView，标题为"日志窗口"
#Preview("日志窗口") {
    // 使用预填充了示例日志的 Logger 实例
    LogView(logger: previewLogger())
}

/// 创建一个预填充了各类日志条目的 Logger，供 Preview 使用。
/// 包含 info/warning/error/debug 四个级别的示例日志，覆盖不同模块。
private func previewLogger() -> Logger {
    // 创建 Logger 实例，configDirectory 为 nil 表示不持久化到磁盘（仅用于预览）
    let logger = Logger(configDirectory: nil)
    // 示例 info 日志：来自 config 模块
    logger.info("应用启动", module: LogModule.config)
    // 示例 info 日志：SSH 连接成功
    logger.info("已连接 host=192.168.1.1:22", module: "SSH")
    // 示例 warning 日志：主机密钥不匹配
    logger.warning("主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…", module: "HostKey")
    // 示例 error 日志：SSH 认证失败
    logger.error("连接失败 host=192.168.1.1:22; 原因=认证失败", module: "SSH")
    // 示例 debug 日志：FFI 调用记录
    logger.debug("FFI 调用入口: list_hosts", module: "FFI")
    // 返回填充好示例数据的 Logger
    return logger
}
// 结束 DEBUG 条件编译块
#endif
