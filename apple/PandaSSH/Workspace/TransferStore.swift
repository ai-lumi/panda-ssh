import Combine
import Foundation
import SwiftUI

/// 传输方向:上传(本地 → 远程)/ 下载(远程 → 本地)。
enum TransferDirection: Equatable {
    case upload
    case download
}

/// 传输任务六态:排队 / 传输中 / 已暂停 / 已完成 / 失败 / 已取消。
/// 命名与 FFI `TransferStatusEnum` 区分,UI 层保持 `.done` 以匹配原型标签。
enum TransferStatus: String, Equatable {
    case queued
    case running
    case paused
    case done
    case failed
    case cancelled

    /// 徽标文案(与原型 stLabel 一致)。
    var label: String {
        switch self {
        case .queued: "排队"
        case .running: "传输中"
        case .paused: "已暂停"
        case .done: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

/// 单个传输任务。UI 与测试均使用此模型;真实状态来自 `TransferSource`。
/// 当 `groupID` 不为 nil 时,该任务属于某个任务组,组名由 `groupName` 指定。
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
    /// Rust 侧版本号；状态/进度/错误变更时递增，用于增量轮询。
    var version: UInt64 = 0
    /// 模拟专用失败点(字节数),真实 FFI 任务不设置。保留以兼容现有测试。
    var failAt: UInt64?
    /// 是否为批量传输任务(遗留字段,保留以兼容现有 FFI 批量任务)。
    let isBatch: Bool
    /// 批量任务的源路径列表（仅 isBatch 时有效）。
    let batchSources: [String]
    /// 批量任务的目标目录（仅 isBatch 时有效）。
    let batchDestDir: String
    /// 所属任务组 id;nil 表示不属于任何组。
    var groupID: UUID?
    /// 所属任务组名称;nil 表示不属于任何组。
    var groupName: String?
    /// 批量任务等待覆盖确认时的冲突信息；非 nil 表示任务暂停等待用户决策。
    var pendingConflict: PendingConflict?
    /// 实时速度（字节/秒）。
    var liveSpeed: Int64 = 0
    /// 总速度（字节/秒），从开始到当前的平均速率。
    var totalSpeed: Int64 = 0
    /// 预估剩余时间（秒）。
    var estimatedTimeRemaining: TimeInterval? = nil

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
        self.version = record.version
        self.failAt = record.failAt
        self.isBatch = record.isBatch
        self.batchSources = record.batchSources
        self.batchDestDir = record.batchDestDir
        self.groupID = record.groupID
        self.groupName = record.groupName
        self.pendingConflict = record.pendingConflict
        self.liveSpeed = record.speed
        self.totalSpeed = record.totalSpeed
        self.estimatedTimeRemaining = record.etaSeconds
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
    /// Rust 侧版本号；状态/进度/错误变更时递增。
    let version: UInt64
    /// 模拟源内部失败点,真实 FFI 源为 nil。
    let failAt: UInt64?
    /// 是否为批量传输任务。
    let isBatch: Bool
    /// 批量任务的源路径列表。
    let batchSources: [String]
    /// 批量任务的目标目录。
    let batchDestDir: String
    /// 所属任务组 id;nil 表示不属于任何组。
    let groupID: UUID?
    /// 所属任务组名称;nil 表示不属于任何组。
    let groupName: String?
    /// 批量任务等待覆盖确认时的冲突信息；非 nil 表示任务暂停等待用户决策。
    let pendingConflict: PendingConflict?
    /// 实时速度（字节/秒），由 Rust 后端计算。
    var speed: Int64 = 0
    /// 总速度（字节/秒），由 Rust 后端计算。
    var totalSpeed: Int64 = 0
    /// 预估剩余秒数，由 Rust 后端计算。
    var etaSeconds: Double? = nil
}

/// 传输任务数据来源抽象。真实实现调用 Rust FFI;模拟实现保留原
/// `TransferStore` 的 tick 驱动状态机,供 Preview 与单元测试使用。
/// 任务源的修订契约。nil 表示源不提供缓存提示，每拍直接读取快照。
protocol TaskRevisionSource: AnyObject {
    func changeRevision() -> UInt64?
}

extension TaskRevisionSource {
    func changeRevision() -> UInt64? { nil }
}

protocol TransferSource: TaskRevisionSource {
    /// 启动传输并返回任务 id(UUID 字符串)。
    /// `size` 对下载为必需(远端已知大小);上传可由实现自行从本地文件计算。
    func enqueueTransfer(
        direction: TransferDirection,
        hostID: String,
        localPath: String,
        remotePath: String,
        size: UInt64,
        password: String?,
        passphrase: String?,
        groupID: String?,
        groupName: String?
    ) -> String

    /// 取消指定任务。
    func cancelTransfer(id: String)

    /// 暂停指定任务。
    func pauseTransfer(id: String)

    /// 继续已暂停任务。
    func resumeTransfer(id: String)

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

/// 批量传输源抽象。
protocol BatchTransferSource: TaskRevisionSource {
    /// 启动批量上传并返回任务 id。
    func enqueueBatchUpload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String

    /// 启动批量下载并返回任务 id。
    func enqueueBatchDownload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String

    /// 取消批量任务。
    func cancelBatchTransfer(id: String)

    /// 查询全部批量任务当前状态。
    func listBatchTransfers() -> [BatchTransferRecord]
}

/// 批量传输源返回的记录。
struct BatchTransferRecord: Equatable {
    let id: UUID
    let direction: TransferDirection
    let name: String
    let size: UInt64
    let transferred: UInt64
    let status: TransferStatus
    let sources: [String]
    let destDir: String
    let hostID: String
    let error: String?
    /// 等待覆盖确认时的冲突信息；非 nil 表示任务暂停等待用户决策。
    let pendingConflict: PendingConflict?
    /// 所属任务组 id;nil 表示不属于任何组。
    let groupID: UUID?
    /// 所属任务组名称;nil 表示不属于任何组。
    let groupName: String?
}

// MARK: - 真实 FFI 源

/// 通过 UniFFI 调用 Rust 任务注册表。
final class FFITransferSource: TransferSource, BatchTransferSource {
    func changeRevision() -> UInt64? { transferChangeCounter() }

    func enqueueTransfer(
        direction: TransferDirection,
        hostID: String,
        localPath: String,
        remotePath: String,
        size: UInt64,
        password: String?,
        passphrase: String?,
        groupID: String?,
        groupName: String?
    ) -> String {
        let ffiDirection: TransferDirectionEnum = direction == .upload ? .upload : .download
        return try! startTransfer(
            direction: ffiDirection,
            hostId: hostID,
            localPath: localPath,
            remotePath: remotePath,
            size: size,
            password: password,
            passphrase: passphrase,
            groupId: groupID,
            groupName: groupName
        )
    }

    func cancelTransfer(id: String) {
        _ = try? transferCancel(taskId: id)
    }

    func pauseTransfer(id: String) {
        _ = try? transferPause(taskId: id)
    }

    func resumeTransfer(id: String) {
        _ = try? transferResume(taskId: id)
    }

    func retryTransfer(id: String) -> String {
        try! transferRetry(taskId: id)
    }

    func listTransfers() -> [TransferRecord] {
        (try? transferList())?.map { TransferRecord(ffiRecord: $0) } ?? []
    }

    func enqueueBatchUpload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String {
        // TODO: FFI 层暂未支持 groupID/groupName，传 nil
        try! startBatchUpload(
            hostId: hostID,
            sources: sources,
            destDir: destDir,
            password: password,
            passphrase: passphrase
        )
    }

    func enqueueBatchDownload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String {
        // TODO: FFI 层暂未支持 groupID/groupName，传 nil
        try! startBatchDownload(
            hostId: hostID,
            sources: sources,
            destDir: destDir,
            password: password,
            passphrase: passphrase
        )
    }

    func cancelBatchTransfer(id: String) {
        _ = try? batchTransferCancel(taskId: id)
    }

    func listBatchTransfers() -> [BatchTransferRecord] {
        (try? batchTransferList())?.map { BatchTransferRecord(ffiRecord: $0) } ?? []
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
    var groupID: UUID?
    var groupName: String?
}

/// 模拟批量传输内部任务。与真实 Rust 行为一致：创建时总大小未知（为 0），
/// 规划完成后由模拟源在 tick 中回填；这里简化为创建后立即视为已规划。
private struct MockBatchTask: Equatable {
    let id: String
    let direction: TransferDirection
    let sources: [String]
    let destDir: String
    let hostID: String
    var size: UInt64
    var transferred: UInt64 = 0
    var status: TransferStatus = .queued
    var speed: Double = 0
    var groupID: UUID? = nil
    var groupName: String? = nil
}

final class MockTransferSource: TransferSource, BatchTransferSource {
    static let maxConcurrent = 3

    private var tasks: [MockTask] = []
    private var batchTasks: [MockBatchTask] = []
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
        size: UInt64,
        password: String?,
        passphrase: String?,
        groupID: String?,
        groupName: String?
    ) -> String {
        let index = addedCount
        addedCount += 1
        let id = UUID().uuidString
        let name = (localPath as NSString).lastPathComponent
        // 模拟源也按传输语义保存 source/destination,与真实 UI 一致。
        let (source, destination) = direction == .upload
            ? (localPath, remotePath)
            : (remotePath, localPath)
        var task = MockTask(
            id: id,
            direction: direction,
            name: name,
            size: size,
            source: source,
            destination: destination,
            hostID: hostID
        )
        task.groupID = groupID.flatMap { UUID(uuidString: $0) }
        task.groupName = groupName
        if failRule(index), task.size > 0 {
            task.failAt = UInt64(Double(task.size) * (0.3 + random() * 0.4))
        }
        tasks.append(task)
        pump()
        return id
    }

    func cancelTransfer(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .running || tasks[index].status == .queued || tasks[index].status == .paused else { return }
        tasks[index].status = .cancelled
        pump()
    }

    func pauseTransfer(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .running || tasks[index].status == .queued else { return }
        tasks[index].status = .paused
    }

    func resumeTransfer(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .paused else { return }
        tasks[index].status = .queued
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
        for index in batchTasks.indices where batchTasks[index].status == .running {
            batchTasks[index].transferred = min(batchTasks[index].size, batchTasks[index].transferred + UInt64(batchTasks[index].speed * 0.1))
            if batchTasks[index].transferred >= batchTasks[index].size {
                batchTasks[index].transferred = batchTasks[index].size
                batchTasks[index].status = .done
            }
        }
        pump()
    }

    func clearFinished() {
        tasks.removeAll { $0.status != .running && $0.status != .queued }
        batchTasks.removeAll { $0.status != .running && $0.status != .queued }
    }

    private func pump() {
        let runningCount = tasks.count { $0.status == .running } + batchTasks.count { $0.status == .running }
        var slots = Self.maxConcurrent - runningCount
        guard slots > 0 else { return }
        for index in tasks.indices where tasks[index].status == .queued && slots > 0 {
            tasks[index].status = .running
            tasks[index].speed = max(64 * 1024, Double(tasks[index].size) / (40 + random() * 80))
            slots -= 1
        }
        for index in batchTasks.indices where batchTasks[index].status == .queued && slots > 0 {
            batchTasks[index].status = .running
            batchTasks[index].speed = max(64 * 1024, Double(batchTasks[index].size) / (40 + random() * 80))
            slots -= 1
        }
    }

    private func mockRecord(_ task: MockTask) -> TransferRecord {
        var record = TransferRecord(
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
            version: 0,
            failAt: task.failAt,
            isBatch: false,
            batchSources: [],
            batchDestDir: "",
            groupID: task.groupID,
            groupName: task.groupName,
            pendingConflict: nil
        )
        // 模拟源的速度计算：仅运行中任务有速度，与 Rust 后端行为一致
        if task.status == .running && task.speed > 0 {
            record.speed = Int64(task.speed)
            record.totalSpeed = Int64(task.speed)
            let remaining = Double(task.size - task.transferred)
            record.etaSeconds = remaining / task.speed
        }
        return record
    }

    func enqueueBatchUpload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String {
        let id = UUID().uuidString
        var task = MockBatchTask(
            id: id,
            direction: .upload,
            sources: sources,
            destDir: destDir,
            hostID: hostID,
            size: 0
        )
        task.groupID = groupID.flatMap { UUID(uuidString: $0) }
        task.groupName = groupName
        batchTasks.append(task)
        pump()
        return id
    }

    func enqueueBatchDownload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String {
        let id = UUID().uuidString
        var task = MockBatchTask(
            id: id,
            direction: .download,
            sources: sources,
            destDir: destDir,
            hostID: hostID,
            size: 0
        )
        task.groupID = groupID.flatMap { UUID(uuidString: $0) }
        task.groupName = groupName
        batchTasks.append(task)
        pump()
        return id
    }

    func cancelBatchTransfer(id: String) {
        guard let index = batchTasks.firstIndex(where: { $0.id == id }) else { return }
        guard batchTasks[index].status == .running || batchTasks[index].status == .queued else { return }
        batchTasks[index].status = .cancelled
        pump()
    }

    func listBatchTransfers() -> [BatchTransferRecord] {
        batchTasks.map { mockBatchRecord($0) }
    }

private func mockBatchRecord(_ task: MockBatchTask) -> BatchTransferRecord {
        BatchTransferRecord(
            id: UUID(uuidString: task.id) ?? UUID(),
            direction: task.direction,
            name: batchName(task),
            size: task.size,
            transferred: task.transferred,
            status: task.status,
            sources: task.sources,
            destDir: task.destDir,
            hostID: task.hostID,
            error: nil,
            pendingConflict: nil,
            groupID: task.groupID,
            groupName: task.groupName
        )
    }

    private func batchName(_ task: MockBatchTask) -> String {
        let count = task.sources.count
        if count == 0 { return "批量\(task.direction == .upload ? "上传" : "下载")" }
        let first = (task.sources[0] as NSString).lastPathComponent
        if count == 1 { return first }
        return "\(first) 等 \(count) 项"
    }
}

// MARK: - TransferStore

/// 传输任务队列。默认使用真实 FFI 源;Preview 与测试可注入 `MockTransferSource`。
/// 真实源通过轮询 `transferChangeCounter()` 检测变化,仅在计数器变化时刷新任务列表;
/// 模拟源由 tick 驱动状态机前进。
@MainActor
final class TransferStore: ObservableObject {
    static let maxConcurrent = 3

    @Published private(set) var tasks: [TransferTask] = []
    /// 应用停机开始后不再接受新的传输注册，避免取消快照与新任务交错。
    @Published private(set) var isAcceptingNewTasks = true

    private let source: any TransferSource
    private let batchSource: (any BatchTransferSource)?
    /// 真实源下被用户清除的终态任务 id;FFI 暂不提供删除接口,先在 UI 层隐藏。
    private var hiddenIDs: Set<UUID> = []
    /// 进度轮询订阅;仅在存在活跃任务时启动,空转时取消以节省 CPU。
    private var polling: AnyCancellable?
    /// 上一次观察到的任务状态，用于终态转换日志。
    private var lastSeenStatuses: [UUID: TransferStatus] = [:]
    /// Rust 侧传输变更计数器;仅在值变化时重新读取任务列表,避免无变化时重复触发 UI。
    private var lastRevisions: [UInt64?]?

    init(source: any TransferSource, batchSource: (any BatchTransferSource)? = nil) {
        self.source = source
        self.batchSource = batchSource
    }

    /// 默认构造:App 运行时使用真实 FFI。
    convenience init() {
        self.init(source: FFITransferSource(), batchSource: FFITransferSource())
    }

    /// 测试/Preview 用构造:保留原模拟状态机,参数语义与旧实现一致。
    convenience init(failRule: ((Int) -> Bool)? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        let mock = MockTransferSource(failRule: failRule, random: random)
        self.init(source: mock, batchSource: mock)
    }

    /// 进行中 + 排队中的任务数(工具栏徽标用)。
    var activeCount: Int {
        tasks.count { $0.status == .running || $0.status == .queued }
    }

    /// 按 groupID 聚合的任务组视图;无组任务不在这里出现。
    var taskGroups: [TransferGroup] {
        let grouped = Dictionary(grouping: tasks.filter { $0.groupID != nil }) { $0.groupID! }
        return grouped.map { (groupID, tasks) in
            TransferGroup(
                id: groupID,
                name: tasks.first?.groupName ?? "",
                direction: tasks.first?.direction ?? .upload,
                tasks: tasks.sorted { $0.source < $1.source }
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// 新增任务并入队,立即尝试调度。
    /// `source`/`destination` 为传输语义:上传时 source=本地/destination=远程,
    /// 下载时 source=远程/destination=本地。内部再映射为 FFI 所需的 localPath/remotePath。
    /// 当 `groupID` 与 `groupName` 同时提供时,该任务会被归入对应任务组。
    @discardableResult
    func add(
        direction: TransferDirection,
        name: String,
        size: UInt64,
        source: String,
        destination: String,
        hostID: String = "",
        groupID: UUID? = nil,
        groupName: String? = nil,
        password: String? = nil,
        passphrase: String? = nil
    ) -> UUID {
        guard isAcceptingNewTasks else { return UUID() }
        let (localPath, remotePath) = direction == .upload
            ? (source, destination)
            : (destination, source)
        let id = self.source.enqueueTransfer(
            direction: direction,
            hostID: hostID,
            localPath: localPath,
            remotePath: remotePath,
            size: size,
            password: password,
            passphrase: passphrase,
            groupID: groupID?.uuidString,
            groupName: groupName
        )
        let uuid = UUID(uuidString: id) ?? UUID()
        refresh()
        startPollingIfNeeded()
        return uuid
    }

    /// 新增批量上传任务。
    @discardableResult
    func addBatchUpload(
        sources: [String],
        destDir: String,
        groupID: UUID? = nil,
        groupName: String? = nil,
        hostID: String = "",
        password: String? = nil,
        passphrase: String? = nil
    ) -> UUID {
        guard isAcceptingNewTasks else { return UUID() }
        guard let batchSource = batchSource else { return UUID() }
        let id = batchSource.enqueueBatchUpload(
            hostID: hostID,
            sources: sources,
            destDir: destDir,
            groupID: groupID?.uuidString,
            groupName: groupName,
            password: password,
            passphrase: passphrase
        )
        refresh()
        startPollingIfNeeded()
        return UUID(uuidString: id) ?? UUID()
    }

    /// 进度步进:真实源检查变更计数器,仅在变化时刷新;模拟源推进状态机并刷新。
    /// 每步都重新构造任务视图并与当前 tasks 比较,仅在真正变化时写入,
    /// 既保证模拟源进度被刷新,也避免 FFI 侧无变化时重复触发 UI。
    func tick(seconds dt: Double = 0.1) {
        source.tick()
        let revisions = readRevisions()
        if revisions[0] != nil,
           batchSource == nil || revisions[1] != nil,
           revisions == lastRevisions {
            adjustPollingFrequency()
            return
        }
        // 捕获列表之前的修订；读取期间发生的新事件留给下一拍。
        lastRevisions = revisions
        var records = source.listTransfers()
        if let batchSource = batchSource {
            records += batchSource.listBatchTransfers()
                .map { TransferRecord(batchRecord: $0) }
        }
        let next = records
            .map { makeTask(from: $0) }
            .filter { !hiddenIDs.contains($0.id) }
        if next != tasks {
            tasks = next
        }
        adjustPollingFrequency()
    }

    /// 取消进行中或排队中的任务;终态任务与未知 id 为 no-op。
    func cancel(id: UUID) {
        if let task = tasks.first(where: { $0.id == id }) {
            if task.isBatch {
                batchSource?.cancelBatchTransfer(id: id.uuidString)
            } else {
                source.cancelTransfer(id: id.uuidString)
            }
        }
        refresh()
        adjustPollingFrequency()
    }

    /// 查询全部批量传输任务当前状态。
    func listBatchTransfers() -> [BatchTransferRecord] {
        batchSource?.listBatchTransfers() ?? []
    }

    /// 重试失败任务;非失败任务为 no-op。
    func retry(id: UUID) {
        _ = source.retryTransfer(id: id.uuidString)
        refresh()
        startPollingIfNeeded()
    }

    /// 暂停运行中或排队中的任务;终态任务、批量任务与未知 id 为 no-op。
    func pause(id: UUID) {
        if let task = tasks.first(where: { $0.id == id }), !task.isBatch,
           task.status == .running || task.status == .queued {
            source.pauseTransfer(id: id.uuidString)
        }
        refresh()
    }

    /// 继续已暂停任务;非暂停任务、批量任务与未知 id 为 no-op。
    func resume(id: UUID) {
        if tasks.first(where: { $0.id == id })?.status == .paused {
            source.resumeTransfer(id: id.uuidString)
        }
        refresh()
        startPollingIfNeeded()
    }

    /// 取消任务组内所有进行中或排队中的任务。
    func cancelGroup(id: UUID) {
        tasks.filter { $0.groupID == id && ($0.status == .running || $0.status == .queued || $0.status == .paused) }
            .forEach { cancel(id: $0.id) }
    }

    /// 重试任务组内所有失败任务。
    func retryGroup(id: UUID) {
        tasks.filter { $0.groupID == id && $0.status == .failed }
            .forEach { retry(id: $0.id) }
    }

    /// 暂停任务组内所有进行中或排队中的任务。
    func pauseGroup(id: UUID) {
        tasks.filter { $0.groupID == id && ($0.status == .running || $0.status == .queued) }
            .forEach { pause(id: $0.id) }
    }

    /// 继续任务组内所有已暂停任务。
    func resumeGroup(id: UUID) {
        tasks.filter { $0.groupID == id && $0.status == .paused }
            .forEach { resume(id: $0.id) }
    }

    /// 取消指定主机的全部活跃传输任务(running/queued/paused)。
    /// 用于删除主机时级联清理:主机已删除,其传输任务无意义。
    func cancelAll(forHostID hostID: String) {
        tasks.filter { $0.hostID == hostID && Self.isActiveStatus($0.status) }
            .forEach { cancel(id: $0.id) }
    }

    /// 应用级停机：先关闭新任务入口，再按当前快照取消所有活跃的单文件与批量任务。
    /// 不等待远端确认；远端结果在进程退出后未知，不能自动重放。
    func beginApplicationShutdown() {
        guard isAcceptingNewTasks else { return }
        isAcceptingNewTasks = false
        refresh()
        tasks.filter { Self.isActiveStatus($0.status) }.forEach { cancel(id: $0.id) }
    }

    private static func isActiveStatus(_ status: TransferStatus) -> Bool {
        status == .running || status == .queued || status == .paused
    }

    /// 清除所有终态任务(已完成/失败/已取消),保留进行中、排队与暂停(与原型一致)。
    func clearFinished() {
        if let mock = source as? MockTransferSource {
            mock.clearFinished()
        } else {
            // 真实源下终态任务加入隐藏集合,避免 FFI 暂无删除接口导致反复出现。
            hiddenIDs.formUnion(tasks.filter { $0.status == .done || $0.status == .failed || $0.status == .cancelled }.map(\.id))
        }
        refresh()
        // 清理已不在 FFI 任务列表中的隐藏记录与分组注册,避免无限增长。
        if !(source is MockTransferSource) {
            var liveIDs = Set(source.listTransfers().map(\.id))
            if let batchSource = batchSource {
                liveIDs.formUnion(batchSource.listBatchTransfers().map(\.id))
            }
            hiddenIDs = hiddenIDs.intersection(liveIDs)
        }
        adjustPollingFrequency()
    }

    private func readRevisions() -> [UInt64?] {
        [source.changeRevision(), batchSource?.changeRevision()]
    }

    func refresh() {
        lastRevisions = readRevisions()
        var records = source.listTransfers()
        if let batchSource = batchSource {
            records += batchSource.listBatchTransfers().map { TransferRecord(batchRecord: $0) }
        }
        tasks = records
            .map { makeTask(from: $0) }
            .filter { !hiddenIDs.contains($0.id) }
    }

    /// 从 `TransferRecord` 构造 `TransferTask`。
    /// 速度指标已由 Rust 后端计算并包含在 record 中，此处仅做终态转换日志。
    private func makeTask(from record: TransferRecord) -> TransferTask {
        let task = TransferTask(record: record)
        let id = task.id
        let previousStatus = lastSeenStatuses[id]
        lastSeenStatuses[id] = task.status

        // 终态转换日志
        if previousStatus != task.status {
            let dir = task.direction == .upload ? "上传" : "下载"
            switch task.status {
            case .done:
                Logger.shared.info("传输完成 name=\(task.name); 方向=\(dir); 大小=\(task.size)", module: LogModule.transfer)
            case .failed:
                Logger.shared.warning("传输失败 name=\(task.name); 方向=\(dir); 原因=\(task.error ?? "未知")", module: LogModule.transfer)
            case .cancelled:
                Logger.shared.info("传输取消 name=\(task.name); 方向=\(dir)", module: LogModule.transfer)
            default:
                break
            }
        }

        // 终态任务清理状态记录，避免内存泄漏。
        if task.status != .queued && task.status != .running && task.status != .paused {
            lastSeenStatuses.removeValue(forKey: id)
        }
        return task
    }

    /// 从 `BatchTransferRecord` 构造 `TransferTask`。
    /// 先转换为内部 `TransferRecord`，再复用单文件任务的构造逻辑。
    private func makeTask(from record: BatchTransferRecord) -> TransferTask {
        makeTask(from: TransferRecord(batchRecord: record))
    }

    /// 当前 Timer 的频率（秒）；nil 表示未启动。
    private var currentPollingInterval: Double?

    /// 根据任务状态选择最合适的轮询频率。
    private func optimalPollingInterval() -> Double? {
        let hasRunning = tasks.contains { $0.status == .running }
        let hasQueued = tasks.contains { $0.status == .queued }
        let hasPaused = tasks.contains { $0.status == .paused }
        if hasRunning || hasQueued || hasPaused {
            // 5Hz：活跃传输时足够流畅
            return 0.2
        }
        let hasTerminal = tasks.contains { [.done, .failed, .cancelled].contains($0.status) }
        if hasTerminal {
            // 1Hz：终态任务仅需偶尔刷新
            return 1.0
        }
        // 无任务时停止
        return nil
    }

    /// 启动或调整轮询频率；已有 Timer 且频率正确时不重建。
    private func startPollingIfNeeded() {
        let optimal = optimalPollingInterval()
        guard let interval = optimal else {
            polling?.cancel()
            polling = nil
            currentPollingInterval = nil
            return
        }
        if currentPollingInterval == interval { return }
        polling?.cancel()
        currentPollingInterval = interval
        polling = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    /// tick() 结束后根据当前任务状态调整频率。
    private func adjustPollingFrequency() {
        startPollingIfNeeded()
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
        self.version = UInt64(ffiRecord.version)
        self.failAt = nil
        self.isBatch = false
        self.batchSources = []
        self.batchDestDir = ""
        // 上传:本地 → 远程;下载:远程 → 本地。
        let isUpload = ffiRecord.direction == .upload
        self.source = isUpload ? ffiRecord.localPath : ffiRecord.remotePath
        self.destination = isUpload ? ffiRecord.remotePath : ffiRecord.localPath
        self.name = (source as NSString).lastPathComponent
        self.pendingConflict = nil
        self.speed = Int64(ffiRecord.speed)
        self.totalSpeed = Int64(ffiRecord.totalSpeed)
        self.etaSeconds = ffiRecord.etaSeconds
        self.groupID = ffiRecord.groupId.flatMap { UUID(uuidString: $0) }
        self.groupName = ffiRecord.groupName
    }
}

private extension TransferStatus {
    init(ffiStatus: TransferStatusEnum) {
        switch ffiStatus {
        case .queued: self = .queued
        case .running: self = .running
        case .paused: self = .paused
        case .completed: self = .done
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }

    init(batchStatus: BatchTransferStatusEnum) {
        switch batchStatus {
        case .queued: self = .queued
        case .running: self = .running
        // 等待覆盖确认：UI 状态机无独立状态，呈现为排队等待（弹窗由 SftpSessionStore 处理）。
        case .waitingForConflict: self = .queued
        case .completed: self = .done
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

private extension TransferRecord {
    init(batchRecord: BatchTransferRecord) {
        self.id = batchRecord.id
        self.direction = batchRecord.direction
        self.status = batchRecord.status
        self.size = batchRecord.size
        self.transferred = batchRecord.transferred
        self.hostID = batchRecord.hostID
        self.error = batchRecord.error
        self.version = 0
        self.failAt = nil
        self.isBatch = true
        self.batchSources = batchRecord.sources
        self.batchDestDir = batchRecord.destDir
        self.source = batchRecord.sources.first ?? ""
        self.destination = batchRecord.destDir
        self.groupID = batchRecord.groupID
        self.groupName = batchRecord.groupName
        self.pendingConflict = batchRecord.pendingConflict
        let count = batchRecord.sources.count
        if count == 0 {
            self.name = "批量\(batchRecord.direction == .upload ? "上传" : "下载")"
        } else if count == 1 {
            self.name = (self.source as NSString).lastPathComponent
        } else {
            self.name = "\((self.source as NSString).lastPathComponent) 等 \(count) 项"
        }
    }
}

private extension BatchTransferRecord {
    init(ffiRecord: BatchTransferStatusRecord) {
        self.id = UUID(uuidString: ffiRecord.id) ?? UUID()
        self.direction = ffiRecord.direction == .upload ? .upload : .download
        self.status = TransferStatus(batchStatus: ffiRecord.status)
        self.size = ffiRecord.totalSize
        self.transferred = ffiRecord.transferred
        self.hostID = ffiRecord.hostId
        self.sources = ffiRecord.sources
        self.destDir = ffiRecord.destDir
        self.error = ffiRecord.error
        self.pendingConflict = ffiRecord.pendingConflict.map { conflict in
            PendingConflict(
                name: (conflict.itemDestination as NSString).lastPathComponent,
                sourceSize: conflict.sourceSize,
                sourceDate: conflict.sourceMtime.map { Date(timeIntervalSince1970: Double($0)) },
                targetSize: conflict.targetSize,
                targetDate: conflict.targetMtime.map { Date(timeIntervalSince1970: Double($0)) }
            )
        }
        // FFI 层暂未返回 groupID/groupName，设为 nil
        self.groupID = nil
        self.groupName = nil
        let count = ffiRecord.sources.count
        if count == 0 {
            self.name = "批量\(self.direction == .upload ? "上传" : "下载")"
        } else if count == 1 {
            self.name = (ffiRecord.sources[0] as NSString).lastPathComponent
        } else {
            self.name = "\((ffiRecord.sources[0] as NSString).lastPathComponent) 等 \(count) 项"
        }
    }
}

// MARK: - 环境注入（非订阅）

/// `\.transferStore` 环境键：只存实例引用，不建立订阅关系。
/// 与 `.environmentObject` 的区别：读取该值的视图不会因 store 的
/// `@Published tasks`（传输期间 5Hz 发布）而失效重渲染；
/// 需要实时刷新的视图（传输页/任务行/侧栏角标）应以 `@ObservedObject`
/// 显式订阅或由父视图参数注入。
private struct TransferStoreEnvironmentKey: EnvironmentKey {
    /// 未注入时的兜底：Mock 空源实例，不触碰 FFI，仅防预览/测试漏注入。
    /// 环境值默认值在 SwiftUI 渲染（主线程）时首次求值，用
    /// assumeIsolated 表达该约束；正常路径必须显式注入。
    static let defaultValue: TransferStore = MainActor.assumeIsolated {
        TransferStore(failRule: nil)
    }
}

extension EnvironmentValues {
    var transferStore: TransferStore {
        get { self[TransferStoreEnvironmentKey.self] }
        set { self[TransferStoreEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// 以非订阅环境值注入 TransferStore（区别于 environmentObject 的订阅语义）。
    func transferStore(_ store: TransferStore) -> some View {
        environment(\.transferStore, store)
    }
}

/// 任务组：一组共享 groupID 的传输任务。
struct TransferGroup: Identifiable, Equatable {
    let id: UUID
    let name: String
    let direction: TransferDirection
    let tasks: [TransferTask]

    /// 组内所有任务的总字节数。
    var totalSize: UInt64 { tasks.reduce(0) { $0 + $1.size } }
    /// 组内已传输字节总数。
    var transferred: UInt64 { tasks.reduce(0) { $0 + $1.transferred } }
    /// 0...1 的组级进度。
    var progress: Double {
        totalSize == 0 ? 1 : min(1, Double(transferred) / Double(totalSize))
    }
    /// 聚合后的组级状态：按 running > paused > queued > failed > cancelled > done 的优先级。
    var status: TransferStatus {
        let statuses = Set(tasks.map(\.status))
        if statuses.contains(.running) { return .running }
        if statuses.contains(.paused) { return .paused }
        if statuses.contains(.queued) { return .queued }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.cancelled) { return .cancelled }
        return .done
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
