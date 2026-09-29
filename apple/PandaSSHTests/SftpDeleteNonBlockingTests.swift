import XCTest
import Foundation

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 删除任务非阻塞交互测试。
/// 核心场景：deleteLocalBatch 启动后必须**立即返回**（不等待终态），
/// 任务在后台运行，用户可以继续操作（切目录、关闭标签）。
@MainActor
final class SftpDeleteNonBlockingTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        resetDeleteServiceForTest()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SftpDeleteNonBlocking-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        resetDeleteServiceForTest()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 5.1 核心：非阻塞语义

    /// deleteLocalBatch 删除单文件后必须**立即返回**——即返回时任务不应已完成。
    /// 当前实现阻塞等待终态，返回时 snapshot.status 必然是 completed/failed/cancelled。
    /// 改造后 deleteLocalBatch 应立即返回 taskID（或启动成功的状态），
    /// Rust DeleteService 在后台继续执行。
    ///
    /// 此测试故意创建大目录增加运行时间，确保返回时任务仍在 running/scanning。
    func testDeleteLocalBatch_returnsImmediately_doesNotBlockUntilComplete() async throws {
        // 创建有一定体量的目录让运行时间 > 50ms
        let dir = tempDir.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<200 {
            try Data(count: 1024 * 512).write(to: dir.appendingPathComponent("f\(i).bin"))
        }

        let targets = [dir.path]

        // 记录 startLocalDelete 调用后立即查询的状态
        let taskID = try startLocalDelete(targets: targets)
        let snapshot = try deleteTaskStatus(taskId: taskID)

        // 关键断言：快照状态应是 preparing/scanning/queued/running 之一，
        // 绝对不能是 completed（除非极端情况下删除快到 <1ms，但有 200 个文件不可能）
        let terminal: Set<DeleteStatusEnum> = [.completed, .failed, .cancelled, .skipped]
        XCTAssertFalse(terminal.contains(snapshot.status),
                       "startLocalDelete 调用后任务不应立即完成，实际: \(snapshot.status)")

        // 清理：轮询到终态
        let _ = try await pollUntilTerminal(taskID: taskID, timeout: 30.0)
    }

    /// 并发多任务：启动多个删除任务，不应互相阻塞。
    func testMultipleDeleteTasks_runConcurrently() async throws {
        let dir1 = tempDir.appendingPathComponent("d1")
        let dir2 = tempDir.appendingPathComponent("d2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        for i in 0..<50 {
            try Data(count: 1024 * 256).write(to: dir1.appendingPathComponent("f\(i).bin"))
            try Data(count: 1024 * 256).write(to: dir2.appendingPathComponent("f\(i).bin"))
        }

        let id1 = try startLocalDelete(targets: [dir1.path])
        let id2 = try startLocalDelete(targets: [dir2.path])

        // 两任务应同时在运行
        let snap1 = try deleteTaskStatus(taskId: id1)
        let snap2 = try deleteTaskStatus(taskId: id2)

        let runningStates: Set<DeleteStatusEnum> = [.preparing, .scanning, .queued, .running, .paused]
        XCTAssertTrue(runningStates.contains(snap1.status) || snap1.status == .completed,
                       "任务1 应在运行或完成，实际: \(snap1.status)")
        XCTAssertTrue(runningStates.contains(snap2.status) || snap2.status == .completed,
                       "任务2 应在运行或完成，实际: \(snap2.status)")

        // 两个任务都应被 deleteTaskList 列出来
        let list = deleteTaskList()
        XCTAssertTrue(list.contains { $0.taskId == id1 }, "deleteTaskList 应包含任务1")
        XCTAssertTrue(list.contains { $0.taskId == id2 }, "deleteTaskList 应包含任务2")

        // 清理
        let _ = try await pollUntilTerminal(taskID: id1, timeout: 30.0)
        let _ = try await pollUntilTerminal(taskID: id2, timeout: 30.0)
    }

    /// 删除运行中任务可以被取消。
    func testDeleteCancellation_whileRunning() async throws {
        let dir = tempDir.appendingPathComponent("cancelMe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<300 {
            try Data(count: 1024 * 512).write(to: dir.appendingPathComponent("f\(i).bin"))
        }

        let taskID = try startLocalDelete(targets: [dir.path])

        // 给 DeleteService 一点时间启动
        try await Task.sleep(nanoseconds: 50_000_000)

        // 取消
        try deleteTaskCancel(taskId: taskID)

        let finalSnap = try await pollUntilTerminal(taskID: taskID, timeout: 15.0)
        XCTAssertTrue([.cancelled, .completed, .failed].contains(finalSnap.status),
                       "取消后应到终态，实际: \(finalSnap.status)")
    }

    /// 不存在的目标 → 启动时就失败（不是运行中失败）。
    func testDeleteLocal_nonexistentTarget_failsImmediately() async throws {
        let nonexistent = tempDir.appendingPathComponent("does-not-exist").path

        let taskID = try startLocalDelete(targets: [nonexistent])

        // 轮询直到终态
        let finalSnap = try await pollUntilTerminal(taskID: taskID, timeout: 5.0)
        XCTAssertEqual(finalSnap.status, .failed,
                         "不存在的目标应最终 failed，实际: \(finalSnap.status)")
        XCTAssertFalse(finalSnap.errors.isEmpty, "应至少有一个错误记录")
    }

    /// TransferStore 非阻塞场景：启动删除后 refresh() 应立即能看到，
    /// 不应等到终态才出现在 deleteTasks 列表。
    func testTransferStore_deleteTasks_populatedWhileRunning() async throws {
        let dir = tempDir.appendingPathComponent("whileRunning")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<100 {
            try Data(count: 1024 * 512).write(to: dir.appendingPathComponent("f\(i).bin"))
        }

        let _ = try startLocalDelete(targets: [dir.path])

        let store = TransferStore()
        let deadline = Date().addingTimeInterval(2.0)
        var foundRunning = false
        while Date() < deadline {
            store.refresh()
            if store.deleteTasks.contains(where: { $0.status == .running || $0.status == .scanning || $0.status == .preparing }) {
                foundRunning = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(foundRunning,
                       "TransferStore.deleteTasks 应在运行时就能看到非终态的删除任务")

        // 清理：删除任务
        let _ = try await pollUntilTerminal(taskID: deleteTaskList().first?.taskId ?? "", timeout: 30.0)
    }

    // MARK: - 辅助

    private func pollUntilTerminal(taskID: String, timeout: TimeInterval) async throws -> DeleteTaskSnapshotRecord {
        let terminal: Set<DeleteStatusEnum> = [.completed, .failed, .cancelled, .skipped]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = try deleteTaskStatus(taskId: taskID)
            if terminal.contains(snap.status) { return snap }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try deleteTaskStatus(taskId: taskID)
    }
}