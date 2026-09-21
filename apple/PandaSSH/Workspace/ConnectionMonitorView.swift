// =============================================================================
// ConnectionMonitorView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了"连接监控"功能，用于展示当前所有 SSH 连接的实时状态。
// 包含三个核心部分：
// 1. ConnectionMonitorStore —— 数据层，负责从 Rust 后端加载连接快照、执行健康探测
// 2. ConnectionMonitorFormatter —— 格式化工具，将原始数据转为用户可读的中文文本
// 3. ConnectionMonitorView —— SwiftUI 视图层，以卡片列表形式展示连接状态
//
// 连接监控只读取 Rust 快照并触发既有连接的按需探测，不持有凭据或会话内容。
// 视图每秒自动刷新一次数据，同时支持手动刷新和单连接健康探测。
// =============================================================================

import SwiftUI
// 导入 SwiftUI 框架，提供声明式 UI 构建能力

/// 连接监控只读数据仓库。
/// 只读取 Rust 快照并触发既有连接的按需探测，不持有凭据或会话内容。
/// @MainActor 确保所有属性和方法都在主线程执行（因为要更新 UI 绑定的 @Published 属性）。
/// ObservableObject 协议使这个类可以被 SwiftUI 的 @StateObject/@ObservedObject 观察，
/// 当 @Published 属性变化时自动触发视图刷新。
@MainActor
final class ConnectionMonitorStore: ObservableObject {
    /// 快照加载闭包类型：从 Rust 后端获取连接遥测记录列表
    /// @Sendable 表示这个闭包可以安全地跨线程传递
    typealias SnapshotLoader = @Sendable () throws -> [ConnectionTelemetryRecord]
    /// 健康检查闭包类型：根据连接 ID 检查连接健康状态
    typealias HealthChecker = @Sendable (UInt64) throws -> HealthStateEnum

    /// 当前所有连接的遥测记录列表
    /// @Published 使属性变化时自动通知 SwiftUI 刷新视图
    /// private(set) 表示外部只能读取、不能直接修改（必须通过 refresh() 方法更新）
    @Published private(set) var records: [ConnectionTelemetryRecord] = []
    /// 是否正在刷新数据（用于显示加载指示器和禁用刷新按钮）
    @Published private(set) var isRefreshing = false
    /// 正在进行健康检查的连接 ID 集合（用于显示对应卡片上的加载指示器）
    @Published private(set) var checkingConnectionIDs: Set<UInt64> = []
    /// 错误信息（nil 表示无错误，非 nil 时触发 alert 弹窗）
    @Published var errorMessage: String?

    /// 快照加载闭包（从 Rust 后端读取连接状态）
    private let snapshotLoader: SnapshotLoader
    /// 健康检查闭包（对单个连接执行探测）
    private let healthChecker: HealthChecker

    /// 初始化数据仓库
    /// - Parameters:
    ///   - snapshotLoader: 快照加载函数，默认调用 connectionTelemetryList()（Rust FFI）
    ///   - healthChecker: 健康检查函数，默认调用 connectionHealthCheck(connectionId:)（Rust FFI）
    /// 测试时可以注入自定义闭包来模拟后端行为
    init(
        snapshotLoader: @escaping SnapshotLoader = { connectionTelemetryList() },
        healthChecker: @escaping HealthChecker = { try connectionHealthCheck(connectionId: $0) }
    ) {
        self.snapshotLoader = snapshotLoader
        self.healthChecker = healthChecker
    }

    /// 刷新所有连接的遥测数据。
    /// 从 Rust 后端加载最新快照，合并到现有记录中。
    /// 使用 guard !isRefreshing 防止重复刷新（避免并发请求）。
    func refresh() async {
        guard !isRefreshing else { return }
        // 如果已经在刷新中，直接返回，避免重复请求
        isRefreshing = true
        // 标记为刷新中（UI 会据此显示加载指示器）
        defer { isRefreshing = false }
        // defer 确保无论成功还是失败，刷新结束后都会将标记重置为 false
        do {
            let snapshot = try await FFIBackground.run(snapshotLoader)
            // 在后台线程执行 FFI 调用，避免阻塞主线程
            // FFIBackground.run 会将闭包调度到后台线程执行并返回结果
            let merged = mergedRecords(from: snapshot)
            // 将新快照与现有记录合并（保持引用稳定性，减少不必要的视图刷新）
            if merged != records {
                records = merged
                // 只有数据真正变化时才更新 @Published 属性，触发视图刷新
            }
            errorMessage = nil
            // 刷新成功，清除之前的错误信息
        } catch {
            errorMessage = Self.errorSummary(error)
            // 刷新失败，记录错误摘要（会触发 alert 弹窗）
        }
    }

    /// 以连接 ID 固定排序；未变化的值沿用既有快照，避免无意义地发布整个列表。
    /// 这个优化可以减少 SwiftUI 的 diff 计算量，提升列表渲染性能。
    /// - Parameter snapshot: 从后端获取的最新快照
    /// - Returns: 合并后的记录列表（按 ID 排序，未变化的记录沿用旧引用）
    private func mergedRecords(from snapshot: [ConnectionTelemetryRecord]) -> [ConnectionTelemetryRecord] {
        let existingRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        // 将现有记录转为字典，key 是连接 ID，value 是记录对象
        // 这样可以用 O(1) 时间查找某个 ID 对应的旧记录
        return snapshot
            .sorted { $0.id < $1.id }
            // 按连接 ID 升序排列，确保列表顺序稳定
            .map { record in existingRecords[record.id] == record ? existingRecords[record.id]! : record }
            // 对于每条新记录：如果旧数据中有相同 ID 且内容相同的记录，沿用旧引用
            // 否则使用新记录。这样可以避免 @Published 触发不必要的视图刷新
    }

    /// 对指定连接执行健康探测。
    /// 健康探测会向远程服务器发送一个轻量级请求，确认连接是否仍然可用。
    /// - Parameter connectionID: 要检查的连接 ID
    func checkHealth(connectionID: UInt64) async {
        guard !checkingConnectionIDs.contains(connectionID) else { return }
        // 如果该连接正在检查中，不重复发起
        checkingConnectionIDs.insert(connectionID)
        // 将连接 ID 加入"正在检查"集合（UI 会据此显示加载指示器）
        defer { checkingConnectionIDs.remove(connectionID) }
        // 检查完成后从集合中移除
        do {
            let state = try await FFIBackground.run { [healthChecker] in
                try healthChecker(connectionID)
            }
            // 在后台线程执行健康检查 FFI 调用
            if let index = records.firstIndex(where: { $0.id == connectionID }) {
                records[index].healthState = state
                // 找到对应连接，更新其健康状态
                // 这会触发 @Published 通知，刷新对应卡片的健康状态徽标
            }
            errorMessage = nil
            // 成功，清除错误信息
        } catch {
            errorMessage = Self.errorSummary(error)
            // 失败，记录错误信息
        }
    }

    /// 将错误转换为简短的中文摘要文本。
    /// 对于"连接不存在"这种常见错误，给出友好的中文提示；
    /// 其他错误使用系统提供的 localizedDescription。
    /// - Parameter error: 捕获到的错误
    /// - Returns: 用户可读的错误描述字符串
    private static func errorSummary(_ error: Error) -> String {
        if let pandaError = error as? PandaError,
           case let PandaError.UnknownConnection(id) = pandaError {
            // 如果是"未知连接"错误（连接 ID 不存在或已结束）
            return "连接 #\(id) 不存在或已结束"
        }
        return error.localizedDescription
        // 其他错误使用系统默认的错误描述
    }
}

/// 连接监控格式化工具集。
/// 提供将原始数据（时间戳、字节数、状态枚举等）转换为用户可读中文文本的方法。
/// 这是一个工具枚举（无 case，不可实例化），所有方法都是静态的。
enum ConnectionMonitorFormatter {
    /// 将毫秒时间戳格式化为日期时间字符串。
    /// 例如：1699000000000 -> "2023年11月3日 下午4:26:40"
    /// - Parameter milliseconds: 自 1970-01-01 以来的毫秒数
    /// - Returns: 格式化的日期时间字符串（ abbreviated 日期 + standard 时间）
    static func timestamp(_ milliseconds: UInt64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        // 将毫秒转为秒，创建 Date 对象
            .formatted(date: .abbreviated, time: .standard)
        // 格式化：abbreviated = "2023年11月3日"，standard = "下午4:26:40"
    }

    /// 将字节数格式化为人类可读的文件大小字符串。
    /// 使用二进制单位（KiB = 1024 B），保留一位小数。
    /// 例如：1536 -> "1.5 KiB"，1048576 -> "1.0 MiB"
    /// - Parameter value: 字节数
    /// - Returns: 格式化后的字符串
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        // 二进制单位列表：从字节到艾字节
        guard value > 0 else { return "0 B" }
        // 0 字节直接返回 "0 B"
        var amount = Double(value)
        // 将字节数转为浮点数，方便做除法
        var unit = 0
        // 当前单位索引（0=B, 1=KiB, 2=MiB...）
        while amount >= 1_024, unit < units.count - 1 {
            // 当数值 >= 1024 且还没到最大单位时，升级到更大的单位
            amount /= 1_024
            // 除以 1024（二进制单位换算）
            unit += 1
            // 单位索引加 1
        }
        if unit == 0 { return "\(value) B" }
        // 如果单位仍是 B（小于 1024 字节），显示整数形式
        return String(format: "%.1f %@", amount, units[unit])
        // 否则显示一位小数 + 单位名
    }

    /// 将字节每秒格式化为速率字符串。
    /// 例如：1048576 -> "1.0 MiB/s"
    /// - Parameter value: 每秒字节数
    /// - Returns: 格式化后的速率字符串
    static func rate(_ value: UInt64) -> String { "\(bytes(value))/s" }
    // 复用 bytes() 方法格式化数值，追加 "/s" 表示"每秒"

    /// 将 Socket 传输状态枚举转为中文描述。
    /// - Parameter state: Socket 连接状态
    /// - Returns: 中文描述文本
    static func transport(_ state: ConnectionStateEnum) -> String {
        switch state {
        case .connecting: "Socket 连接中"
        // 正在建立 TCP 连接
        case .active: "Socket 活跃"
        // TCP 连接已建立且正在传输数据
        case .idle: "Socket 空闲（正常）"
        // TCP 连接正常但暂时没有数据传输
        case .closed: "Socket 已关闭"
        // TCP 连接已正常关闭
        case .failed: "Socket 异常"
        // TCP 连接异常断开或出错
        }
    }

    /// 将 SSH 连接状态枚举转为中文描述。
    /// - Parameter state: SSH 连接状态
    /// - Returns: 中文描述文本
    static func ssh(_ state: SshConnectionStateEnum) -> String {
        switch state {
        case .connecting: "SSH 协商中"
        // 正在进行 SSH 握手和密钥交换
        case .authenticated: "SSH 已认证"
        // 身份验证成功，可以正常使用
        case .closed: "SSH 已关闭"
        // SSH 会话已正常关闭
        case .failed: "SSH 异常"
        // SSH 连接出错
        }
    }

    /// 将健康探测状态枚举转为中文描述。
    /// - Parameter state: 健康状态
    /// - Returns: 中文描述文本
    static func health(_ state: HealthStateEnum) -> String {
        switch state {
        case .unknown: "未检查"
        // 尚未执行健康探测
        case .healthy: "健康"
        // 探测成功，连接正常
        case .unavailable: "不可用"
        // 探测失败，连接不可用
        }
    }

    /// 将通道类型枚举转为中文描述。
    /// SSH 连接中可以打开多种通道（终端、SFTP、命令执行等）。
    /// - Parameter kind: 通道类型
    /// - Returns: 中文描述文本
    static func channelKind(_ kind: ChannelKindEnum) -> String {
        switch kind {
        case .shell: "终端"
        // 交互式终端通道
        case .sftp: "SFTP"
        // 文件传输通道
        case .exec: "命令"
        // 单次命令执行通道
        }
    }

    /// 将通道状态枚举转为中文描述。
    /// - Parameter state: 通道状态
    /// - Returns: 中文描述文本
    static func channelState(_ state: ChannelStateEnum) -> String {
        switch state {
        case .open: "可用"
        // 通道已打开，可以正常通信
        case .closed: "已关闭"
        // 通道已正常关闭
        case .failed: "不可交互"
        // 通道异常，无法继续交互
        }
    }
}

/// 连接监控主视图。
/// 以卡片列表形式展示所有 SSH 连接的实时状态信息，包括：
/// - Socket 和 SSH 连接状态
/// - 健康探测结果
/// - 数据传输量（接收/发送字节数和速率）
/// - 通道信息和错误消息
///
/// 视图每秒自动刷新一次数据（通过 .task 中的循环实现）。
@MainActor
struct ConnectionMonitorView: View {
    /// 数据仓库对象，管理连接遥测数据
    /// @StateObject 表示这个视图拥有并管理 store 的生命周期
    @StateObject private var store: ConnectionMonitorStore

    /// 默认初始化：创建一个新的数据仓库
    init() {
        _store = StateObject(wrappedValue: ConnectionMonitorStore())
        // 使用默认参数创建 ConnectionMonitorStore（走真实 FFI 调用）
    }

    /// 测试初始化：注入自定义数据仓库
    /// - Parameter store: 外部创建的 store（测试中可以注入 mock 数据）
    init(store: ConnectionMonitorStore) {
        _store = StateObject(wrappedValue: store)
        // 使用外部注入的 store
    }

    /// 视图主体：根据数据状态显示空态或连接卡片列表
    var body: some View {
        Group {
            // Group 用于将多个视图组合在一起，以便应用共同的修饰符
            if store.records.isEmpty, !store.isRefreshing {
                // 如果没有连接记录且不在刷新中 -> 显示空态
                ContentUnavailableView(
                    // ContentUnavailableView 是 SwiftUI 内置的空态视图
                    // 显示一个大图标 + 标题 + 描述文字，居中展示
                    "暂无连接",
                    // 标题
                    systemImage: "network.slash",
                    // SF Symbol 图标：带斜线的网络图标，表示没有连接
                    description: Text("建立终端或 SFTP 会话后，可在这里查看 Socket、SSH、通道和流量状态。")
                    // 描述文字：告诉用户如何产生连接数据
                )
            } else {
                // 有连接记录或正在刷新 -> 显示滚动列表
                ScrollView {
                    // 可垂直滚动的容器
                    LazyVStack(spacing: 12) {
                        // LazyVStack：延迟加载的垂直栈，只有滚动到可见区域时才创建视图
                        // spacing: 12 表示卡片之间的间距为 12 点
                        explanation
                        // 顶部说明条（蓝色信息提示）
                        ForEach(store.records, id: \.id) { connection in
                            // 遍历所有连接记录，为每条记录创建一个卡片
                            // id: \.id 使用连接 ID 作为唯一标识，帮助 SwiftUI 高效 diff
                            connectionCard(connection)
                            // 渲染单个连接的状态卡片
                        }
                    }
                    .padding()
                    // .padding() 在内容四周添加默认内边距（约 16 点）
                }
            }
        }
        .navigationTitle("连接监控")
        // .navigationTitle 设置导航栏标题（iPadOS 显示在导航栏中央）
        .toolbar {
            // .toolbar 添加导航栏工具栏按钮
            ToolbarItem(placement: .primaryAction) {
                // placement: .primaryAction 将按钮放在工具栏的主要操作位置（通常在右侧）
                Button {
                    // Button 的 action 闭包：点击时执行
                    Task { await store.refresh() }
                    // 创建一个新的 Task 来执行异步刷新操作
                } label: {
                    // label 闭包：定义按钮的外观
                    Label("刷新", systemImage: "arrow.clockwise")
                    // Label 组合图标和文字：顺时针箭头图标 + "刷新"文字
                }
                .disabled(store.isRefreshing)
                // .disabled：刷新进行中时禁用按钮，防止重复点击
            }
        }
        .overlay {
            // .overlay 在视图上方叠加一层内容
            if store.isRefreshing, store.records.isEmpty { ProgressView("读取连接状态…") }
            // 仅在刷新中且无数据时显示加载指示器（首次加载时）
            // ProgressView 是一个旋转的加载圆圈 + 提示文字
        }
        .task {
            // .task 在视图出现时启动一个异步任务，视图消失时自动取消
            while !Task.isCancelled {
                // 循环执行，直到任务被取消（视图消失时）
                await store.refresh()
                // 刷新数据
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // 等待 1 秒（10^9 纳秒 = 1 秒）
                // try? 忽略取消抛出的异常
                // 这样就实现了每秒自动刷新一次的效果
            }
        }
        .alert(
            // .alert 显示系统警告弹窗
            "连接监控",
            // 弹窗标题
            isPresented: Binding(
                // isPresented 控制弹窗是否显示
                get: { store.errorMessage != nil },
                // 当有错误信息时显示弹窗
                set: { if !$0 { store.errorMessage = nil } }
                // 弹窗关闭时（$0 == false），清除错误信息
            )
        ) {
            Button("好", role: .cancel) {}
            // 弹窗中的按钮："好"，角色为 cancel（在 macOS 上按 Esc 也会触发）
        } message: {
            Text(store.errorMessage ?? "未知错误")
            // 弹窗的消息内容：显示错误信息，如果没有则显示"未知错误"
        }
    }

    /// 顶部信息说明条。
    /// 蓝色背景的信息提示，告诉用户流量数据的含义。
    private var explanation: some View {
        Label {
            // Label 的文本部分（标题右侧或下方的文字）
            Text("流量为应用层实际读写的加密 SSH 字节与通道逻辑数据，不含 TCP/IP 头和重传。空闲表示近期无数据，不是异常。")
                .font(.caption)
                // .font(.caption) 使用系统 caption 字体（小号字体，约 12pt）
                .foregroundStyle(.secondary)
                // .foregroundStyle(.secondary) 使用次要文字颜色（灰色，比正文淡）
        } icon: {
            // Label 的图标部分（左侧的图标）
            Image(systemName: "info.circle")
            // SF Symbol 图标：圆圈中的 i，表示信息提示
                .foregroundStyle(.blue)
                // 图标颜色设为蓝色
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // .frame 设置布局：最大宽度撑满父容器，内容左对齐
        .padding(12)
        // .padding(12) 在四周添加 12 点的内边距
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        // .background 设置背景：
        // 颜色：蓝色 8% 不透明度（非常淡的蓝色）
        // 形状：圆角矩形，圆角半径 10 点
    }

    /// 单个连接的状态卡片。
    /// 展示一个 SSH 连接的完整信息：地址、状态徽标、流量、时间、错误、通道等。
    /// - Parameter connection: 连接遥测记录
    /// - Returns: 一个卡片样式的 SwiftUI 视图
    private func connectionCard(_ connection: ConnectionTelemetryRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 垂直栈容器
            // alignment: .leading 所有内容左对齐
            // spacing: 12 子视图间距 12 点
            HStack(alignment: .top) {
                // 水平栈：标题区域 + 检查按钮
                // alignment: .top 顶部对齐
                VStack(alignment: .leading, spacing: 3) {
                    // 垂直栈：地址 + 详情
                    Text(connection.address)
                    // 显示连接地址（如 "192.168.1.100:22"）
                        .font(.headline)
                        // .font(.headline) 使用标题字体（粗体，约 17pt）
                    Text("Session #\(connection.id) · \(connection.ownerKind) \(connection.ownerId) · 主机 \(connection.hostId)")
                    // 显示会话 ID、所有者类型/ID、主机 ID
                        .font(.caption)
                        // .font(.caption) 小号字体
                        .foregroundStyle(.secondary)
                        // 次要文字颜色（灰色）
                }
                Spacer()
                // Spacer 弹性空间：将右侧按钮推到最右边
                Button {
                    // 健康检查按钮
                    Task { await store.checkHealth(connectionID: connection.id) }
                    // 点击后异步执行健康探测
                } label: {
                    if store.checkingConnectionIDs.contains(connection.id) {
                        // 如果该连接正在检查中
                        ProgressView().controlSize(.small)
                        // 显示小号加载指示器（旋转圆圈）
                    } else {
                        Label("检查", systemImage: "stethoscope")
                        // 否则显示"检查"按钮 + 听诊器图标
                    }
                }
                .buttonStyle(.bordered)
                // .buttonStyle(.bordered) 使用带边框的按钮样式
                .disabled(store.checkingConnectionIDs.contains(connection.id))
                // 正在检查时禁用按钮
            }

            VStack(alignment: .leading, spacing: 6) { statusBadges(connection) }
            // 状态徽标区域：显示 Socket 状态、SSH 状态、健康探测结果
            // 每个状态用一个彩色胶囊形徽标表示

            HStack(spacing: 24) {
                // 水平栈：接收流量 + 发送流量
                // spacing: 24 两个指标之间间距 24 点
                trafficMetric("接收", total: connection.receivedBytes, rate: connection.receiveBytesPerSecond)
                // 接收流量指标：总字节数 + 每秒速率
                trafficMetric("发送", total: connection.sentBytes, rate: connection.sendBytesPerSecond)
                // 发送流量指标
                Spacer()
                // 弹性空间推到左边
            }

            Text(
                // 时间信息行：建立时间、最近活动时间、最近检查时间
                "建立：\(ConnectionMonitorFormatter.timestamp(connection.createdAtMs))  ·  "
                // 连接建立时间
                    + "最近活动：\(ConnectionMonitorFormatter.timestamp(connection.lastActivityAtMs))  ·  "
                // 最近一次数据传输时间
                    + "最近检查：\(connection.lastHealthCheckAtMs.map(ConnectionMonitorFormatter.timestamp) ?? "尚未检查")"
                // 最近一次健康检查时间，如果从未检查则显示"尚未检查"
            )
            .font(.caption2.monospacedDigit())
            // .font(.caption2) 更小的字体（约 11pt）
            // .monospacedDigit() 数字使用等宽字体，防止数字变化时文字抖动
            .foregroundStyle(.tertiary)
            // .foregroundStyle(.tertiary) 使用第三级文字颜色（更淡的灰色）

            if let error = connection.lastError, !error.isEmpty {
                // 如果有错误信息且不为空
                Label(error, systemImage: "exclamationmark.triangle.fill")
                // 显示错误信息 + 实心警告三角图标
                    .font(.caption)
                    .foregroundStyle(.red)
                    // 红色文字，强调错误
                    .textSelection(.enabled)
                    // .textSelection(.enabled) 允许用户选中和复制错误文本
            }

            if !connection.channels.isEmpty {
                // 如果有通道信息
                Divider()
                // Divider 是一条灰色分隔线
                VStack(spacing: 6) {
                    ForEach(connection.channels, id: \.id) { channel in
                        // 遍历每个通道
                        HStack {
                            // 水平排列：通道类型+ID | 状态 | 流量
                            Text("\(ConnectionMonitorFormatter.channelKind(channel.kind)) #\(channel.id)")
                            // 通道类型和 ID（如"终端 #1"）
                                .font(.callout.weight(.medium))
                                // .callout 约 14pt 字体，.medium 中等粗细
                            Text(ConnectionMonitorFormatter.channelState(channel.state))
                            // 通道状态（如"可用"、"已关闭"）
                                .font(.caption)
                                .foregroundStyle(channel.state == .failed ? .red : .secondary)
                                // 失败状态用红色，其他用灰色
                            Spacer()
                            Text("↓ \(ConnectionMonitorFormatter.bytes(channel.receivedBytes))  ↑ \(ConnectionMonitorFormatter.bytes(channel.sentBytes))")
                            // 通道流量：↓ 接收量  ↑ 发送量
                                .font(.caption.monospacedDigit())
                                // 小号等宽数字字体
                                .foregroundStyle(.secondary)
                                // 灰色文字
                        }
                    }
                }
            }
        }
        .padding(14)
        // 卡片内边距 14 点
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        // 卡片背景：使用系统背景色，形状为圆角矩形（圆角 12 点）
        // .background 是系统自适应颜色，浅色模式下为白色，深色模式下为深灰
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        // .overlay 在卡片上方叠加一个边框：
        // 圆角矩形描边，颜色为 primary（黑色/白色）12% 不透明度
        // 形成一个非常淡的边框效果
    }

    /// 状态徽标集合：显示 Socket 状态、SSH 状态和健康探测结果。
    /// @ViewBuilder 允许在函数体中用自然语法编写多个视图。
    @ViewBuilder
    private func statusBadges(_ connection: ConnectionTelemetryRecord) -> some View {
        statusBadge(
            ConnectionMonitorFormatter.transport(connection.transportState),
            // 将 Socket 状态枚举转为中文文本
            color: transportColor(connection.transportState)
            // 根据状态选择颜色
        )
        statusBadge(ConnectionMonitorFormatter.ssh(connection.sshState), color: sshColor(connection.sshState))
        // SSH 状态徽标
        statusBadge(
            "探测：\(ConnectionMonitorFormatter.health(connection.healthState))",
            // 健康探测状态，前面加"探测："前缀
            color: healthColor(connection.healthState)
        )
    }

    /// 单个状态徽标视图。
    /// 外观为一个彩色胶囊形（Capsule）背景的小标签。
    /// - Parameters:
    ///   - title: 徽标文字（如"Socket 活跃"）
    ///   - color: 徽标颜色（如绿色表示正常）
    /// - Returns: 一个胶囊形徽标视图
    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
        // 显示状态文字
            .font(.caption.weight(.semibold))
            // 字体：caption 大小 + semibold 半粗体
            .foregroundStyle(color)
            // 文字颜色使用传入的颜色
            .padding(.horizontal, 8)
            // 水平内边距 8 点（左右各 8 点）
            .padding(.vertical, 4)
            // 垂直内边距 4 点（上下各 4 点）
            .background(color.opacity(0.12), in: Capsule())
            // 背景：颜色 12% 不透明度，形状为胶囊形（两端半圆）
            // 例如绿色状态 -> 淡绿色胶囊背景
    }

    /// 流量指标视图：显示标题、总字节数和速率。
    /// - Parameters:
    ///   - title: 指标名称（如"接收"或"发送"）
    ///   - total: 总字节数
    ///   - rate: 每秒字节数
    /// - Returns: 一个垂直排列的指标视图
    private func trafficMetric(_ title: String, total: UInt64, rate: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 垂直栈，左对齐，间距 2 点
            Text(title).font(.caption).foregroundStyle(.secondary)
            // 第一行：指标名称（灰色小字，如"接收"）
            Text(ConnectionMonitorFormatter.bytes(total)).font(.body.monospacedDigit().weight(.semibold))
            // 第二行：总字节数（正常大小、等宽数字、半粗体，如"1.5 MiB"）
            Text(ConnectionMonitorFormatter.rate(rate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            // 第三行：速率（灰色小字等宽数字，如"128.0 KiB/s"）
        }
    }

    /// 根据 Socket 传输状态返回对应颜色。
    /// 颜色语义：绿色=正常、蓝色=空闲、橙色=连接中、灰色=已关闭、红色=异常。
    private func transportColor(_ state: ConnectionStateEnum) -> Color {
        switch state {
        case .active: .green
        // 活跃 -> 绿色（正面）
        case .idle: .blue
        // 空闲 -> 蓝色（正常但无活动）
        case .connecting: .orange
        // 连接中 -> 橙色（进行中）
        case .closed: .secondary
        // 已关闭 -> 灰色（中性）
        case .failed: .red
        // 异常 -> 红色（警告）
        }
    }

    /// 根据 SSH 连接状态返回对应颜色。
    private func sshColor(_ state: SshConnectionStateEnum) -> Color {
        switch state {
        case .authenticated: .green
        // 已认证 -> 绿色
        case .connecting: .orange
        // 协商中 -> 橙色
        case .closed: .secondary
        // 已关闭 -> 灰色
        case .failed: .red
        // 异常 -> 红色
        }
    }

    /// 根据健康探测状态返回对应颜色。
    private func healthColor(_ state: HealthStateEnum) -> Color {
        switch state {
        case .unknown: .secondary
        // 未检查 -> 灰色
        case .healthy: .green
        // 健康 -> 绿色
        case .unavailable: .red
        // 不可用 -> 红色
        }
    }
}
