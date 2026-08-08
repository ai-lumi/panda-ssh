import Combine
import Foundation

/// 传输方向:上传(本地 → 远程)/ 下载(远程 → 本地)。
enum TransferDirection: Equatable {
    case upload
    case download
}

/// 传输任务五态(与原型一致):排队 / 传输中 / 已完成 / 失败 / 已取消。
/// 命名与 FFI `TransferStatusEnum` 区分,UI 层保持 `.done` 以匹配原型标签。
enum TransferStatus: String, Equatable {
    case queued
    case running
    case done
    case failed
    case cancelled

    /// 徽标文案(与原型 stLabel 一致)。
    var label: String {
        switch self {
        case .queued: "排队"
        case .running: "传输中"
        case .done: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

/// 单个传输任务。UI 与测试均使用此模型;真实状态来自 `TransferSource`。
struct TransferTask: Identifiable, Equatable {
    let id: UUID
    let direction: TransferDirection
    let name: String
    let size: UInt64
    let source: String
    let destination: String
    let hostID: String
    var transferred: UInt64 = 0
    var status: TransferStatus = .queued
    var error: String?
    /// 模拟专用失败点(字节数),真实 FFI 任务不设置。保留以兼容现有测试。
    var failAt: UInt64?

    /// 0...1 的进度;零字节文件视为已完成。
    var progress: Double {
        size == 0 ? 1 : min(1, Double(transferred) / Double(size))
    }

    var percent: Int { Int(progress * 100) }

    init(record: TransferRecord) {
        self.id = record.id
        self.direction = record.direction
        self.name = record.name
        self.size = record.size
        self.source = record.source
        self.destination = record.destination
        self.hostID = record.hostID
        self.transferred = record.transferred
        self.status = record.status
        self.error = record.error
        self.failAt = record.failAt
    }
}

/// 传输源返回的通用记录,与具体实现(FFI / 模拟)解耦。
struct TransferRecord: Equatable {
    let id: UUID
    let direction: TransferDirection
    let name: String
    let size: UInt64
    let transferred: UInt64
    let status: TransferStatus
    let source: String
    let destination: String
    let hostID: String
    let error: String?
    /// 模拟源内部失败点,真实 FFI 源为 nil。
    let failAt: UInt64?
}

/// 传输任务数据来源抽象。真实实现调用 Rust FFI;模拟实现保留原
/// `TransferStore` 的 tick 驱动状态机,供 Preview 与单元测试使用。
protocol TransferSource: AnyObject {
    /// 启动传输并返回任务 id(UUID 字符串)。
    func enqueueTransfer(
        direction: TransferDirection,
        hostID: String,
        localPath: String,
        remotePath: String,
        password: String?,
        passphrase: String?
    ) -> String

    /// 取消指定任务。
    func cancelTransfer(id: String)

    /// 重试失败任务,返回新任务 id。
    func retryTransfer(id: String) -> String

    /// 查询全部任务当前状态。
    func listTransfers() -> [TransferRecord]

    /// 驱动模拟源前进一个时间步;真实实现为空实现。
    func tick()
}

extension TransferSource {
    func tick() {}
}

// MARK: - 真实 FFI 源

/// 通过 UniFFI 调用 Rust 任务注册表。
final class FFITransferSource: TransferSource {
    func enqueueTransfer(
        direction: TransferDirection,
        hostID: String,
        localPath: String,
        remotePath: String,
        password: String?,
        passphrase: String?
    ) -> String {
        let ffiDirection: TransferDirectionEnum = direction == .upload ? .upload : .download
        return try! startTransfer(
            direction: ffiDirection,
            hostId: hostID,
            localPath: localPath,
            remotePath: remotePath,
            password: password,
            passphrase: passphrase
        )
    }

    func cancelTransfer(id: String) {
        _ = try? transferCancel(taskId: id)
    }

    func retryTransfer(id: String) -> String {
        try! transferRetry(taskId: id)
    }

    func listTransfers() -> [TransferRecord] {
        (try? transferList())?.map { TransferRecord(ffiRecord: $0) } ?? []
    }
}

// MARK: - 模拟源(保持原状态机,供测试/Preview 使用)

/// 模拟传输源内部任务。除 `id` 用 String 便于与协议统一外,语义与原
/// `TransferStore` 一致。
private struct MockTask: Equatable {
    let id: String
    let direction: TransferDirection
    let name: String
    var size: UInt64
    let source: String
    let destination: String
    let hostID: String
    var transferred: UInt64 = 0
    var status: TransferStatus = .queued
    var failAt: UInt64?
    var speed: Double = 0
}

final class MockTransferSource: TransferSource {
    static let maxConcurrent = 3

    private var tasks: [MockTask] = []
    private var addedCount = 0
    private let failRule: (Int) -> Bool
    private let random: () -> Double

    init(failRule: ((Int) -> Bool)? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
        self.failRule = failRule ?? { index in index >= 2 && random() < 1.0 / 3.0 }
    }

    func enqueueTransfer(
        direction: TransferDirection,
        hostID: String,
        localPath: String,
        remotePath: String,
        password: String?,
        passphrase: String?
    ) -> String {
        let index = addedCount
        addedCount += 1
        let id = UUID().uuidString
        let name = (localPath as NSString).lastPathComponent
        var task = MockTask(
            id: id,
            direction: direction,
            name: name,
            size: 0,
            source: localPath,
            destination: remotePath,
            hostID: hostID
        )
        // 模拟源复用 size 字段作为演示大小;真实源从文件系统读取。
        // 调用方通过 name 携带大小约定(旧测试直接传 size 参数给 store.add)。
        // 此处暂时保持简单:模拟源不依赖 size,由 store.add 后续 patch。
        // 实际调用中 store.add 会先用本地 entry 大小创建 record,再注入源。
        if failRule(index), task.size > 0 {
            task.failAt = UInt64(Double(task.size) * (0.3 + random() * 0.4))
        }
        tasks.append(task)
        pump()
        return id
    }

    func cancelTransfer(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .running || tasks[index].status == .queued else { return }
        tasks[index].status = .cancelled
        pump()
    }

    func retryTransfer(id: String) -> String {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .failed else { return id }
        tasks[index].status = .queued
        tasks[index].transferred = 0
        tasks[index].failAt = nil
        pump()
        return id
    }

    func listTransfers() -> [TransferRecord] {
        tasks.map { mockRecord($0) }
    }

    func tick() {
        for index in tasks.indices where tasks[index].status == .running {
            tasks[index].transferred = min(tasks[index].size, tasks[index].transferred + UInt64(tasks[index].speed * 0.1))
            if let failAt = tasks[index].failAt, tasks[index].transferred >= failAt {
                tasks[index].status = .failed
            } else if tasks[index].transferred >= tasks[index].size {
                tasks[index].transferred = tasks[index].size
                tasks[index].status = .done
            }
        }
        pump()
    }

    /// 外部(TransferStore)在 add 后根据用户提供的 size 覆盖模拟大小。
    func setSize(id: String, size: UInt64) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].size = size
        if failRule(addedCount - 1), size > 0, tasks[index].failAt == nil {
            tasks[index].failAt = UInt64(Double(size) * (0.3 + random() * 0.4))
        }
    }

    func clearFinished() {
        tasks.removeAll { $0.status != .running && $0.status != .queued }
    }

    private func pump() {
        var slots = Self.maxConcurrent - tasks.count { $0.status == .running }
        guard slots > 0 else { return }
        for index in tasks.indices where tasks[index].status == .queued && slots > 0 {
            tasks[index].status = .running
            tasks[index].speed = max(64 * 1024, Double(tasks[index].size) / (40 + random() * 80))
            slots -= 1
        }
    }

    private func mockRecord(_ task: MockTask) -> TransferRecord {
        TransferRecord(
            id: UUID(uuidString: task.id) ?? UUID(),
            direction: task.direction,
            name: task.name,
            size: task.size,
            transferred: task.transferred,
            status: task.status,
            source: task.source,
            destination: task.destination,
            hostID: task.hostID,
            error: nil,
            failAt: task.failAt
        )
    }
}

// MARK: - TransferStore

/// 传输任务队列。默认使用真实 FFI 源;Preview 与测试可注入 `MockTransferSource`。
/// 真实源通过轮询 `listTransfers()` 刷新;模拟源由 tick 驱动。
@MainActor
final class TransferStore: ObservableObject {
    static let maxConcurrent = 3

    @Published private(set) var tasks: [TransferTask] = []

    private let source: any TransferSource
    /// 真实源下被用户清除的终态任务 id;FFI 暂不提供删除接口,先在 UI 层隐藏。
    private var hiddenIDs: Set<UUID> = []
    /// 进度轮询订阅;仅在存在活跃任务时启动,空转时取消以节省 CPU。
    private var polling: AnyCancellable?

    /// 默认构造:App 运行时使用真实 FFI。
    init(source: any TransferSource = FFITransferSource()) {
        self.source = source
    }

    /// 测试/Preview 用构造:保留原模拟状态机,参数语义与旧实现一致。
    convenience init(failRule: ((Int) -> Bool)? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.init(source: MockTransferSource(failRule: failRule, random: random))
    }

    /// 进行中 + 排队中的任务数(工具栏徽标用)。
    var activeCount: Int {
        tasks.count { $0.status == .running || $0.status == .queued }
    }

    /// 新增任务并入队,立即尝试调度。
    @discardableResult
    func add(
        direction: TransferDirection,
        name: String,
        size: UInt64,
        source localPath: String,
        destination remotePath: String,
        hostID: String = "",
        password: String? = nil,
        passphrase: String? = nil
    ) -> UUID {
        let id = source.enqueueTransfer(
            direction: direction,
            hostID: hostID,
            localPath: localPath,
            remotePath: remotePath,
            password: password,
            passphrase: passphrase
        )
        // 模拟源需要 size 来驱动进度;真实源忽略此值。
        if let mock = source as? MockTransferSource {
            mock.setSize(id: id, size: size)
        }
        refresh()
        startPollingIfNeeded()
        return UUID(uuidString: id) ?? UUID()
    }

    /// 进度步进:真实源仅刷新列表,模拟源同时推进状态机。
    /// 列表无变化时不赋值,避免空转时持续触发 SwiftUI 重绘。
    func tick(seconds dt: Double = 0.1) {
        source.tick()
        let next = source.listTransfers()
            .map { TransferTask(record: $0) }
            .filter { !hiddenIDs.contains($0.id) }
        if next != tasks {
            tasks = next
        }
        stopPollingIfIdle()
    }

    /// 取消进行中或排队中的任务;终态任务与未知 id 为 no-op。
    func cancel(id: UUID) {
        source.cancelTransfer(id: id.uuidString)
        refresh()
        stopPollingIfIdle()
    }

    /// 重试失败任务;非失败任务为 no-op。
    func retry(id: UUID) {
        _ = source.retryTransfer(id: id.uuidString)
        refresh()
        startPollingIfNeeded()
    }

    /// 清除所有终态任务(已完成/失败/已取消),保留进行中与排队(与原型一致)。
    func clearFinished() {
        if let mock = source as? MockTransferSource {
            mock.clearFinished()
        } else {
            // 真实源下终态任务加入隐藏集合,避免 FFI 暂无删除接口导致反复出现。
            hiddenIDs.formUnion(tasks.filter { $0.status != .running && $0.status != .queued }.map(\.id))
        }
        refresh()
        stopPollingIfIdle()
    }

    private func refresh() {
        tasks = source.listTransfers()
            .map { TransferTask(record: $0) }
            .filter { !hiddenIDs.contains($0.id) }
    }

    private func startPollingIfNeeded() {
        guard polling == nil else { return }
        polling = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopPollingIfIdle() {
        guard activeCount == 0 else { return }
        polling?.cancel()
        polling = nil
    }
}

// MARK: - Mapping

private extension TransferRecord {
    init(ffiRecord: TransferStatusRecord) {
        self.id = UUID(uuidString: ffiRecord.id) ?? UUID()
        self.direction = ffiRecord.direction == .upload ? .upload : .download
        self.status = TransferStatus(ffiStatus: ffiRecord.status)
        self.size = ffiRecord.size
        self.transferred = ffiRecord.transferred
        self.hostID = ffiRecord.hostId
        self.error = ffiRecord.error
        self.failAt = nil
        // 上传:本地 → 远程;下载:远程 → 本地。
        let isUpload = ffiRecord.direction == .upload
        self.source = isUpload ? ffiRecord.localPath : ffiRecord.remotePath
        self.destination = isUpload ? ffiRecord.remotePath : ffiRecord.localPath
        self.name = (source as NSString).lastPathComponent
    }
}

private extension TransferStatus {
    init(ffiStatus: TransferStatusEnum) {
        switch ffiStatus {
        case .queued: self = .queued
        case .running: self = .running
        case .completed: self = .done
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

/// 字节数格式化(与原型 fmtBytes 一致):<1KB 整数 B,KB/MB 一位小数,GB 两位小数。
func formatBytes(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    if bytes < 1024 { return "\(bytes) B" }
    if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
    if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / 1024 / 1024) }
    return String(format: "%.2f GB", value / 1024 / 1024 / 1024)
}
