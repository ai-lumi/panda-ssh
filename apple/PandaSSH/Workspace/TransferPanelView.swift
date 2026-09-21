// =============================================================================
// TransferPanelView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了全局传输任务面板，用于管理和展示 SFTP 文件传输任务。
// 包含以下核心组件：
// 1. TransferPageView —— 传输任务页面主视图，展示所有传输任务的列表
// 2. GroupRow —— 任务组行视图，展示一组相关文件的传输进度和批量操作
// 3. TransferRow —— 单个传输任务行视图，展示文件传输的详细信息
// 4. StatusBadge —— 六态状态徽标视图，用颜色编码表示任务状态
// 5. TransferTaskPresentation —— 传输任务展示数据模型，格式化端点和路径信息
//
// 传输任务支持分组管理、暂停/继续/取消/重试等操作，
// 并实时显示传输速度、剩余时间和进度条。
// =============================================================================

import SwiftUI
// 导入 SwiftUI 框架

/// 全局传输页面只观察应用共享队列；关闭页面不会影响任务生命周期。
/// 即使关闭此页面，传输任务仍然在后台继续执行。
struct TransferPageView: View {
    /// 传输任务队列管理器
    /// @ObservedObject 观察 store 的 @Published 属性变化，自动刷新视图
    @ObservedObject var store: TransferStore
    /// 当前展开的任务组 ID 集合
    /// @State 是视图的本地状态，视图重建时保留
    @State private var expandedGroups: Set<UUID> = []

    /// 视图主体
    var body: some View {
        VStack(spacing: 0) {
            // 垂直栈，无间距（各区域紧密排列）
            header
            // 顶部标题栏
            Divider()
            // 分隔线
            if store.tasks.isEmpty {
                // 没有传输任务时显示空态
                ContentUnavailableView(
                    "暂无传输任务",
                    // 标题
                    systemImage: "arrow.up.arrow.down",
                    // 上下箭头图标，表示传输
                    description: Text("选中文件后点击「上传 →」或「← 下载」")
                    // 操作提示
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 空态视图撑满整个可用空间，居中显示
            } else {
                List {
                    // List 是 SwiftUI 的列表容器，支持高效滚动和行复用
                    ForEach(store.taskGroups) { group in
                        // 遍历所有任务组
                        GroupRow(
                            group: group,
                            // 任务组数据
                            store: store,
                            // 传输队列管理器
                            isExpanded: expandedGroups.contains(group.id)
                            // 该组是否展开（显示组内文件列表）
                        ) {
                            // 展开/收起的切换回调
                            if expandedGroups.contains(group.id) {
                                expandedGroups.remove(group.id)
                                // 已展开 -> 收起（从集合中移除 ID）
                            } else {
                                expandedGroups.insert(group.id)
                                // 未展开 -> 展开（将 ID 加入集合）
                            }
                        }
                    }
                    ForEach(store.tasks.filter { $0.groupID == nil }.reversed()) { task in
                        // 遍历所有未分组的任务（groupID == nil）
                        // .reversed() 反转顺序，最新的任务显示在最上面
                        TransferRow(task: task, store: store)
                        // 渲染单个任务行
                    }
                }
                .listStyle(.plain)
                // .listStyle(.plain) 使用朴素列表样式（无分组背景色、无圆角）
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 撑满整个可用空间
        .background(.background)
        // 使用系统背景色（浅色=白色，深色=深灰）
    }

    /// 顶部标题栏：显示任务统计和"清除已完成"按钮。
    private var header: some View {
        HStack {
            // 水平排列
            VStack(alignment: .leading, spacing: 4) {
                // 垂直排列，左对齐，间距 4 点
                Text("传输任务")
                    .font(.title2.bold())
                    // 标题字体（约 22pt）+ 粗体
                Text("\(store.activeCount) 个活动任务 · 共 \(store.tasks.count) 项")
                    // 显示活动任务数和总任务数
                    .font(.caption)
                    // 小号字体
                    .foregroundStyle(.secondary)
                    // 灰色文字
            }
            Spacer()
            // 弹性空间：将右侧按钮推到最右边
            Button("清除已完成") { store.clearFinished() }
            // 点击后清除所有已完成/已取消的任务
                .buttonStyle(.bordered)
                // 带边框的按钮样式
        }
        .padding(16)
        // 四周内边距 16 点
    }
}

/// 任务组行:组名、总进度、批量控制;展开后列出组内文件任务。
/// 一个任务组通常对应一次批量上传/下载操作（如拖拽多个文件到 SFTP 窗口）。
private struct GroupRow: View {
    /// 任务组数据
    let group: TransferGroup
    /// 传输队列管理器
    @ObservedObject var store: TransferStore
    /// 是否展开（显示组内文件列表）
    let isExpanded: Bool
    /// 展开/收起的切换回调
    let toggle: () -> Void

    /// 任务组行的视图主体
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 垂直栈，左对齐，间距 5 点
            HStack(spacing: 6) {
                // 第一行：方向图标 + 文件夹图标 + 组名 + 状态徽标
                Image(systemName: group.direction == .upload ? "arrow.up" : "arrow.down")
                // 上传显示向上箭头，下载显示向下箭头
                    .font(.caption.weight(.bold))
                    // 小号粗体
                    .foregroundStyle(group.direction == .upload ? Color.accentColor : Color.green)
                    // 上传用强调色（蓝色），下载用绿色
                Image(systemName: isExpanded ? "folder.open" : "folder")
                // 展开时显示打开的文件夹图标，收起时显示关闭的文件夹
                    .foregroundStyle(Color.blue)
                    // 蓝色图标
                Text(group.name)
                // 组名文本（如"上传 3 个文件到 /home/deploy"）
                    .font(.callout.bold())
                    // callout 字体（约 14pt）+ 粗体
                    .lineLimit(1)
                    // 限制为单行显示，超出部分截断
                Spacer(minLength: 4)
                // 弹性空间，最小长度 4 点
                StatusBadge(status: group.status)
                // 状态徽标（如"传输中"、"已完成"等）
            }
            ProgressView(value: group.progress)
            // 进度条：value 范围 0.0 ~ 1.0
                .progressViewStyle(.linear)
                // .linear 使用线性进度条样式（水平条形）
                .tint(barColor)
                // 进度条颜色：完成=绿色、失败=红色、其他=强调色
            HStack(spacing: 8) {
                // 第三行：百分比 + 已传输/总大小 + 操作按钮 + 展开/收起按钮
                Text("\(Int(group.progress * 100))%")
                // 显示百分比（如"45%"）
                Text("\(formatBytes(group.transferred)) / \(formatBytes(group.totalSize))")
                // 显示已传输字节数 / 总字节数（如"1.5 MiB / 3.3 MiB"）
                Spacer()
                // 弹性空间
                groupOperations
                // 操作按钮（暂停/继续/取消/重试，根据状态显示不同按钮）
                Button {
                    toggle()
                    // 点击展开/收起按钮时调用 toggle 回调
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    // 展开时显示向上箭头，收起时显示向下箭头
                        .font(.caption2.weight(.semibold))
                        // 更小的字体 + 半粗体
                }
                .buttonStyle(.plain)
                // .plain 无边框无背景的按钮样式
            }
            .font(.system(.caption, design: .monospaced))
            // 整行使用 caption 大小 + 等宽字体设计
            .foregroundStyle(.secondary)
            // 灰色文字
            if isExpanded {
                // 展开时显示组内文件列表
                VStack(spacing: 4) {
                    ForEach(group.tasks) { task in
                        // 遍历组内每个任务
                        TransferRow(task: task, store: store, indented: true)
                        // 渲染任务行，indented=true 表示缩进（表示是子项）
                    }
                }
                .padding(.leading, 12)
                // 左侧内边距 12 点（缩进效果）
                .padding(.top, 4)
                // 顶部内边距 4 点
            }
        }
        .padding(.horizontal, 10)
        // 水平内边距 10 点
        .padding(.vertical, 8)
        // 垂直内边距 8 点
    }

    /// 进度条颜色：根据组状态返回不同颜色。
    private var barColor: Color {
        switch group.status {
        case .done: .green
        // 完成 -> 绿色
        case .failed: .red
        // 失败 -> 红色
        default: .accentColor
        // 其他状态 -> 系统强调色（通常蓝色）
        }
    }

    /// 组级操作按钮：根据组状态显示不同的操作按钮。
    @ViewBuilder
    private var groupOperations: some View {
        switch group.status {
        case .running, .queued:
            // 运行中或排队中 -> 显示"暂停"和"取消"按钮
            HStack(spacing: 8) {
                Button("暂停") { store.pauseGroup(id: group.id) }
                // 暂停整个组的传输
                    .buttonStyle(.borderless)
                    // 无边框按钮（纯文字按钮）
                    .font(.caption)
                Button("取消") { store.cancelGroup(id: group.id) }
                // 取消整个组的传输
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .paused:
            // 已暂停 -> 显示"继续"和"取消"按钮
            HStack(spacing: 8) {
                Button("继续") { store.resumeGroup(id: group.id) }
                // 恢复传输
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("取消") { store.cancelGroup(id: group.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .failed:
            // 失败 -> 显示"重试"按钮
            Button("重试") { store.retryGroup(id: group.id) }
            // 重新尝试失败的传输
                .buttonStyle(.borderless)
                .font(.caption)
        case .done, .cancelled:
            EmptyView()
            // 完成或已取消 -> 不显示任何操作按钮
        }
    }
}

/// 单个传输任务行。
/// 展示一个文件的传输详情：文件名、源/目标路径、进度、速度、操作按钮等。
private struct TransferRow: View {
    /// 应用全局模型（用于获取主机名称）
    @EnvironmentObject private var model: AppModel
    /// 是否显示完整路径（可切换）
    @State private var showsPaths = false
    /// 传输任务数据
    let task: TransferTask
    /// 传输队列管理器
    @ObservedObject var store: TransferStore
    /// 是否缩进（组内子项为 true，独立任务为 false）
    var indented: Bool = false

    /// 任务行的视图主体
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 垂直栈，左对齐，间距 5 点
            HStack(spacing: 6) {
                // 第一行：方向图标 + 文件名 + 状态徽标
                Image(systemName: task.direction == .upload ? "arrow.up" : "arrow.down")
                // 上传=向上箭头，下载=向下箭头
                    .font(.caption.weight(.bold))
                    .foregroundStyle(task.direction == .upload ? Color.accentColor : Color.green)
                    // 上传=蓝色，下载=绿色
                Text(task.name)
                // 文件名
                    .font(.callout.bold())
                    .lineLimit(1)
                    // 单行显示
                Spacer(minLength: 4)
                StatusBadge(status: task.status)
                // 状态徽标
            }
            ViewThatFits(in: .horizontal) {
                // ViewThatFits 自动选择能在水平方向放得下的第一个视图
                // 宽屏时：源和目标水平并排
                HStack(alignment: .top, spacing: 24) {
                    endpoint(title: "源", name: presentation.sourceEndpoint, path: presentation.sourcePath)
                        .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    // 源端点信息：最小宽度 240，撑满可用空间
                    endpoint(title: "目标", name: presentation.destinationEndpoint, path: presentation.destinationPath)
                        .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    // 目标端点信息
                }
                // 窄屏时：源和目标垂直堆叠
                VStack(alignment: .leading, spacing: 8) {
                    endpoint(title: "源", name: presentation.sourceEndpoint, path: presentation.sourcePath)
                    endpoint(title: "目标", name: presentation.destinationEndpoint, path: presentation.destinationPath)
                }
            }
            Button(showsPaths ? "收起完整路径" : "查看完整路径") { showsPaths.toggle() }
            // 切换完整路径显示/隐藏
                .buttonStyle(.borderless)
                .font(.caption)
            if let error = task.error, task.status == .failed {
                // 如果有错误信息且状态为失败
                Text(error)
                // 显示错误文本
                    .font(.caption2)
                    // 更小的字体
                    .foregroundStyle(.red)
                    // 红色文字
                    .lineLimit(2)
                    // 最多显示两行
            }
            conflictNotice
            // 文件冲突提示（如果目标文件已存在，等待覆盖确认）
            progressBar
            // 进度条
            HStack(spacing: 8) {
                // 进度信息行：百分比 + 已传输/总大小 + 操作按钮
                Text(presentation.progress.map { "\(Int($0 * 100))%" } ?? "—")
                // 显示百分比，如果进度未知则显示"—"
                Text("\(formatBytes(task.transferred)) / \(formatBytes(task.size))")
                // 已传输/总大小
                Spacer()
                operations
                // 操作按钮
            }
            .font(.system(.caption, design: .monospaced))
            // 等宽数字字体
            .foregroundStyle(.secondary)
            // 灰色文字
            speedInfo
            // 速度信息行：实时速度、平均速度、剩余时间
        }
        .padding(.horizontal, indented ? 8 : 10)
        // 水平内边距：组内子项 8 点，独立任务 10 点
        .padding(.vertical, indented ? 5 : 8)
        // 垂直内边距：组内子项 5 点，独立任务 8 点
    }

    /// 批量任务等待覆盖确认时的提示行。
    /// 当目标文件已存在且等待用户确认是否覆盖时，显示橙色警告。
    @ViewBuilder
    private var conflictNotice: some View {
        if let conflict = task.pendingConflict {
            // 如果有待处理的文件冲突
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                // 圆圈感叹号图标
                    .foregroundStyle(Color.orange)
                    // 橙色图标
                Text("\u{201C}\(conflict.name)\u{201D} 已存在，等待覆盖确认")
                // 显示冲突文件名和提示文字
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption2)
            // 小号字体
            .foregroundStyle(.orange)
            // 橙色文字
            .padding(.top, 2)
            // 顶部间距 2 点
        }
    }

    /// 原生线性进度条:完成绿色、失败红色,其余强调色。
    private var progressBar: some View {
        ProgressView(value: presentation.progress)
        // 进度条，value 范围 0.0~1.0
            .progressViewStyle(.linear)
            // 线性样式（水平条）
            .tint(barColor)
            // 进度条颜色
            .animation(.linear(duration: 0.12), value: task.transferred)
            // 进度变化时的动画：0.12 秒线性过渡
            // 让进度条平滑增长，而不是跳跃式更新
    }

    /// 实时速度、总速度与剩余时间。
    private var speedInfo: some View {
        HStack(spacing: 8) {
            // 水平排列，间距 8 点
            Text("速度 \(formatSpeed(presentation.liveSpeed))")
            // 实时传输速度（如"速度 1.2 MiB/s"）
            Text("(") + Text("均速 \(formatSpeed(task.totalSpeed))") + Text(")")
            // 平均速度（如"(均速 980 KiB/s)"）
            if task.status == .running, let remaining = task.estimatedTimeRemaining {
                // 仅在传输中且有预估剩余时间时显示
                Spacer()
                // 弹性空间推到右侧
                Text("剩余 \(formatDuration(remaining))")
                // 显示剩余时间（如"剩余 2分30秒"）
            }
        }
        .font(.system(.caption2, design: .monospaced))
        // 更小的等宽字体
        .foregroundStyle(.secondary)
        // 灰色文字
    }

    /// 传输任务展示数据。
    /// 将原始任务数据格式化为展示用的端点名称和路径。
    private var presentation: TransferTaskPresentation {
        TransferTaskPresentation(
            task: task,
            hostName: model.hosts.first(where: { $0.id == task.hostID })?.name
            // 从主机列表中查找对应主机的名称
        )
    }

    /// 端点信息视图：显示端点名称（如"本地"或主机名）和路径。
    /// - Parameters:
    ///   - title: 端点标签（"源"或"目标"）
    ///   - name: 端点名称（如"本地"或远程主机名）
    ///   - path: 文件路径
    /// - Returns: 端点信息视图
    private func endpoint(title: String, name: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // 垂直排列，左对齐，间距 3 点
            Text("\(title)：\(name)")
            // 显示"源：本地"或"目标：myserver"
                .font(.caption.weight(.semibold))
                // 小号半粗体
            Text(path)
            // 显示文件路径
                .font(.system(.caption, design: .monospaced))
                // 等宽字体（路径对齐更整齐）
                .foregroundStyle(.secondary)
                // 灰色文字
                .lineLimit(showsPaths ? nil : 1)
                // 显示完整路径时不限行数，否则限制为 1 行
                .truncationMode(.middle)
                // 截断模式：从中间截断（保留路径的开头和结尾）
                // 例如："/Users/.../file.txt"
                .textSelection(.enabled)
                // 允许用户选中和复制路径文本
                .help(path)
                // 鼠标悬停时显示完整路径作为 tooltip
                .accessibilityLabel("\(title)路径：\(path)")
                // VoiceOver 朗读的无障碍标签
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 水平撑满，左对齐
    }

    /// 进度条颜色
    private var barColor: Color {
        switch task.status {
        case .done: .green
        case .failed: .red
        default: .accentColor
        }
    }

    /// 任务操作按钮：根据任务状态显示不同按钮。
    @ViewBuilder
    private var operations: some View {
        switch task.status {
        case .running, .queued:
            // 运行中或排队中
            if task.isBatch {
                // 批量任务：只显示"取消"（批量任务不支持单独暂停）
                Button("取消") { store.cancel(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                // 单个任务：显示"暂停"和"取消"
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
            // 已暂停：显示"继续"和"取消"
            HStack(spacing: 8) {
                Button("继续") { store.resume(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("取消") { store.cancel(id: task.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .failed:
            // 失败
            if task.isBatch {
                EmptyView()
                // 批量任务失败不显示重试按钮（需要逐个重试子任务）
            } else {
                Button("重试") { store.retry(id: task.id) }
                // 单个任务：显示"重试"按钮
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .done, .cancelled:
            EmptyView()
            // 完成或已取消：不显示操作按钮
        }
    }
}

/// 六态徽标(配色与原型 .st.* 一致)。
/// 用颜色编码表示传输任务的当前状态，外观为彩色胶囊形背景的小标签。
private struct StatusBadge: View {
    /// 传输状态枚举值
    let status: TransferStatus

    /// 徽标视图主体
    var body: some View {
        Text(status.label)
        // 显示状态文本（如"传输中"、"已完成"、"失败"等）
            .font(.caption2.weight(.semibold))
            // 字体：更小的 caption2 + 半粗体
            .padding(.horizontal, 7)
            // 水平内边距 7 点
            .padding(.vertical, 1)
            // 垂直内边距 1 点（上下很窄）
            .background(background, in: Capsule())
            // 背景颜色 + 胶囊形（两端半圆的圆角矩形）
            .foregroundStyle(foreground)
            // 文字颜色
    }

    /// 背景颜色：根据状态返回不同的半透明颜色。
    private var background: Color {
        switch status {
        case .queued: Color.secondary.opacity(0.25)
        // 排队中 -> 灰色 25% 不透明
        case .running: Color.accentColor.opacity(0.15)
        // 传输中 -> 强调色 15% 不透明（淡蓝色）
        case .paused: Color.orange.opacity(0.15)
        // 已暂停 -> 橙色 15% 不透明（淡橙色）
        case .done: Color.green.opacity(0.16)
        // 已完成 -> 绿色 16% 不透明（淡绿色）
        case .failed: Color.red.opacity(0.14)
        // 失败 -> 红色 14% 不透明（淡红色）
        case .cancelled: Color.secondary.opacity(0.2)
        // 已取消 -> 灰色 20% 不透明
        }
    }

    /// 文字颜色：根据状态返回对应的前景色。
    private var foreground: Color {
        switch status {
        case .queued: .secondary
        // 排队中 -> 灰色
        case .running: .accentColor
        // 传输中 -> 强调色（蓝色）
        case .paused: .orange
        // 已暂停 -> 橙色
        case .done: .green
        // 已完成 -> 绿色
        case .failed: .red
        // 失败 -> 红色
        case .cancelled: .secondary
        // 已取消 -> 灰色
        }
    }
}

#if DEBUG
// 调试预览：展示传输任务面板的示例数据
#Preview("全局传输任务") {
    let store = TransferStore(failRule: { _ in false })
    // 创建传输队列，failRule 永远返回 false（不会模拟失败）
    store.add(direction: .upload, name: "deploy.tar.gz", size: 18_432_000,
              source: "/Users/luowenqiang/deploy.tar.gz", destination: "/home/deploy/deploy.tar.gz")
    // 添加一个上传任务示例
    store.add(direction: .download, name: "app.log", size: 10_485_760,
              source: "/home/deploy/logs/app.log", destination: "/Users/luowenqiang/app.log")
    // 添加一个下载任务示例
    store.tick(seconds: 2)
    // 模拟 2 秒的传输进度
    return TransferPageView(store: store)
        .environmentObject(AppModel.previewModel())
        // 注入预览用的 AppModel
}
#endif

/// 仅负责端点标签和未知进度的展示，不改变任务记录或传输规则。
/// 将原始 TransferTask 数据格式化为视图层需要的展示信息。
struct TransferTaskPresentation {
    /// 源端点名称（如"本地"或远程主机名）
    let sourceEndpoint: String
    /// 目标端点名称
    let destinationEndpoint: String
    /// 源文件路径（批量任务可能是多行路径）
    let sourcePath: String
    /// 目标文件路径
    let destinationPath: String
    /// 进度值（0.0~1.0），nil 表示进度未知
    let progress: Double?
    /// 实时传输速度（字节/秒）
    let liveSpeed: Int64

    /// 从 TransferTask 和主机名称初始化展示数据
    /// - Parameters:
    ///   - task: 传输任务原始数据
    ///   - hostName: 远程主机名称（可能为 nil）
    init(task: TransferTask, hostName: String?) {
        let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去除主机名首尾的空白字符和换行符
        let remote = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (task.hostID.isEmpty ? "未知主机" : task.hostID)
        // 确定远程主机显示名：
        // 1. 如果有有效的主机名（非空），使用它
        // 2. 否则如果 hostID 非空，使用 hostID
        // 3. 否则显示"未知主机"
        sourceEndpoint = task.direction == .upload ? "本地" : remote
        // 上传任务的源是"本地"，下载任务的源是远程主机
        destinationEndpoint = task.direction == .upload ? remote : "本地"
        // 上传任务的目标是远程主机，下载任务的目标是"本地"
        sourcePath = task.isBatch && !task.batchSources.isEmpty
            ? task.batchSources.joined(separator: "\n") : task.source
        // 批量任务的源路径是多行（每个源文件一行），单个任务直接用 source
        destinationPath = task.isBatch ? task.batchDestDir : task.destination
        // 批量任务的目标是目标目录，单个任务用完整目标路径
        progress = task.size == 0 && task.status != .done ? nil : task.progress
        // 如果文件大小为 0 且未完成，进度为 nil（无法计算百分比）
        // 否则使用实际进度值
        liveSpeed = task.status == .running ? max(0, task.liveSpeed) : 0
        // 仅在传输中时显示实时速度，其他状态速度为 0
        // max(0, ...) 确保速度不为负数
    }
}
