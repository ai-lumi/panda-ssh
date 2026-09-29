import XCTest
import Foundation

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 删除任务 FFI 集成测试。
/// 覆盖：本地删除完成链路、TransferStore 接入、activeCount 混合计数、reset 隔离。
/// 每个测试独立 reset_delete_service_for_test() + 独立临时目录，互不串扰。
@MainActor
final class DeleteTaskFFITests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        // 1. 重置 Rust DeleteService 全局单例
        resetDeleteServiceForTest()
        // 2. 创建独立临时目录
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteTaskFFITests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // 1. 清理 Rust 全局单例（下一测试 setUp 还会再 reset，这里兜底）
        resetDeleteServiceForTest()
        // 2. 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 场景 1：本地文件删除链路

    /// 单个文件 → startLocalDelete → 轮询 deleteTaskStatus → completed。
    func testLocalDelete_singleFile_completes() async throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let taskID = try startLocalDelete(targets: [file.path])
        XCTAssertFalse(taskID.isEmpty)

        // 轮询直到 completed 或超时
        let snapshot = try await pollUntilTerminal(taskID: taskID, timeout: 10.0)
        XCTAssertEqual(snapshot.status, .completed, "单文件删除应完成，实际: \(snapshot.status)")
        XCTAssertEqual(snapshot.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path) == false,
                      "文件应已被物理删除")
    }

    /// 递归目录删除：创建含多个子文件的目录，整个删除。
    func testLocalDelete_directory_recursive() async throws {
        let dir = tempDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<5 {
            try "content-\(i)".write(
                to: dir.appendingPathComponent("f\(i).txt"),
                atomically: true, encoding: .utf8
            )
        }
        // 子目录嵌套
        let subdir = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "deep".write(to: subdir.appendingPathComponent("deep.txt"),
                         atomically: true, encoding: .utf8)

        let taskID = try startLocalDelete(targets: [dir.path])
        let snapshot = try await pollUntilTerminal(taskID: taskID, timeout: 15.0)
        XCTAssertEqual(snapshot.status, .completed, "目录删除应完成，实际: \(snapshot.status)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path) == false,
                      "目录应已被物理删除")
    }

    // MARK: - 场景 2：TransferStore 接入 Delete 任务

    /// TransferStore(FFI 源) + startLocalDelete → refresh() → deleteTasks 非空。
    func testTransferStore_refresh_populatesDeleteTasks() async throws {
        let file = tempDir.appendingPathComponent("a.bin")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let _ = try startLocalDelete(targets: [file.path])

        // 先直接验证 FFI 层能看到任务
        let directList = deleteTaskList()
        XCTAssertFalse(directList.isEmpty, "startLocalDelete 后 deleteTaskList 应至少有一条")

        // 创建 TransferStore 后反复 refresh 直到 deleteTasks 有内容或超时
        // （跨测试 Rust 全局状态可能有残留，refresh 需要在 deleteChangeCounter 变化后才触发）
        let store = TransferStore()
        let deadline = Date().addingTimeInterval(1.0)
        var found = false
        while Date() < deadline {
            store.refresh()
            if !store.deleteTasks.isEmpty {
                found = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        XCTAssertTrue(found, "refresh() 后 deleteTasks 应被填充；direct=\(directList.count)")

        // 确认内容确实来自删除任务
        let hasDeleteStatus = store.deleteTasks.contains {
            [.running, .completed, .failed].contains($0.status)
        }
        XCTAssertTrue(hasDeleteStatus, "deleteTasks 应包含 running/completed/failed 状态")
    }

    /// activeCount 应包含活跃删除任务。
    func testTransferStore_activeCount_includesRunningDelete() async throws {
        // 启动一个删除任务（目录，有多个文件，能观察到 running 状态）
        let dir = tempDir.appendingPathComponent("bigdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<100 {
            try Data(count: 1024 * 1024).write(to: dir.appendingPathComponent("f\(i).bin"))
        }
        let _ = try startLocalDelete(targets: [dir.path])

        let store = TransferStore()
        store.refresh()

        // activeCount 应该 > 0（至少包含正在执行的删除任务）
        XCTAssertGreaterThan(store.activeCount, 0,
                             "活跃删除任务存在时 activeCount 应 > 0")
    }

    /// 空列表场景：reset 后 deleteTaskList() 应为空。
    func testDeleteTaskList_isEmpty_afterReset() {
        resetDeleteServiceForTest()
        let list = deleteTaskList()
        XCTAssertTrue(list.isEmpty, "reset 后删除任务列表应为空")
        XCTAssertEqual(deleteChangeCounter(), 0, "reset 后变更计数器应为 0")
    }

    // MARK: - 场景 3：混合任务（传输 Mock + 删除 FFI 独立 store）

    /// TransferStore 仅传输任务时 activeCount 计算不包含 deleteTasks（因为 Mock 源跳过）。
    /// 但用真实 FFI 源的 store 才包含。验证两种源的行为差异。
    func testTransferStore_mockSource_skipsDeleteRefresh() {
        // 启动 FFI 删除任务
        let file = tempDir.appendingPathComponent("m.txt")
        try? "m".write(to: file, atomically: true, encoding: .utf8)
        let _ = try? startLocalDelete(targets: [file.path])

        // MockTransferSource 的 changeRevision() -> nil，refresh() 跳过 delete 分支
        let mockStore = TransferStore(failRule: { _ in false })
        mockStore.refresh()
        XCTAssertTrue(mockStore.deleteTasks.isEmpty,
                       "Mock 源 changeRevision 返回 nil，deleteTasks 应保持为空")
    }

    // MARK: - 场景 4：删除取消

    /// startLocalDelete → deleteTaskCancel → 轮询直到 cancelled。
    func testDeleteCancellation_transitionsToCancelled() async throws {
        // 创建较大文件增加运行时间，给取消留出窗口
        let dir = tempDir.appendingPathComponent("cancelDir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<200 {
            try Data(count: 512 * 1024).write(to: dir.appendingPathComponent("f\(i).bin"))
        }

        let taskID = try startLocalDelete(targets: [dir.path])
        // 立即取消（可能在准备阶段或运行阶段）
        try deleteTaskCancel(taskId: taskID)

        let snapshot = try await pollUntilTerminal(taskID: taskID, timeout: 10.0)
        // 取消后的终态可能是 cancelled 或 completed（已全部处理完才收到取消请求）
        let terminalStates: Set<DeleteStatusEnum> = [.cancelled, .completed, .failed]
        XCTAssertTrue(terminalStates.contains(snapshot.status),
                       "取消后应到达终态，实际: \(snapshot.status)")
    }

    // MARK: - 辅助

    /// 轮询 deleteTaskStatus 直到到达终态（completed/failed/cancelled/skipped）或超时。
    private func pollUntilTerminal(taskID: String, timeout: TimeInterval) async throws -> DeleteTaskSnapshotRecord {
        let terminal: Set<DeleteStatusEnum> = [.completed, .failed, .cancelled, .skipped]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = try deleteTaskStatus(taskId: taskID)
            if terminal.contains(snap.status) {
                return snap
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        // 超时：返回最后一次快照
        return try deleteTaskStatus(taskId: taskID)
    }
}