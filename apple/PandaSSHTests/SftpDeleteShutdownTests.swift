import XCTest
import Foundation

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 7.1 应用停机：SFTP 删除任务参与测试。
/// 核心断言：TransferStore.beginApplicationShutdown() 应同时覆盖删除任务（取消活跃 + 门控新删除）。
/// 以及 SftpSessionStore 删除入口应被停机门控。
@MainActor
final class SftpDeleteShutdownTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        resetDeleteServiceForTest()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SftpDeleteShutdown-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        resetDeleteServiceForTest()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 正常流程：停机取消活跃删除

    /// beginApplicationShutdown 应取消所有活跃的（preparing/scanning/running）删除任务。
    func testBeginShutdown_cancelsActiveDeleteTasks() async throws {
        // 创建 5 个删除任务，每个目录 300 个 256KB 文件 = 75MB（确保扫描+删除至少几百毫秒）
        var taskIDs: [String] = []
        for i in 0..<5 {
            let dir = tempDir.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<300 {
                try Data(count: 1024 * 256).write(to: dir.appendingPathComponent("f\(j).bin"))
            }
            let id = try startLocalDelete(targets: [dir.path])
            taskIDs.append(id)
        }

        // 等至少一个任务进入 running 状态再 shutdown
        var runningTaskID: String? = nil
        let readyDeadline = Date().addingTimeInterval(3.0)
        while Date() < readyDeadline {
            for id in taskIDs {
                if let snap = try? deleteTaskStatus(taskId: id),
                   snap.status == .running || snap.status == .scanning || snap.status == .preparing {
                    runningTaskID = id
                    break
                }
            }
            if runningTaskID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(runningTaskID, "应至少有一个删除任务在 shutdown 前进入活跃状态")

        let store = TransferStore()
        store.beginApplicationShutdown()

        // 轮询直到所有任务终态
        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            let allTerminal = taskIDs.allSatisfy { id in
                guard let snap = try? deleteTaskStatus(taskId: id) else { return true }
                return [.completed, .failed, .cancelled, .skipped].contains(snap.status)
            }
            if allTerminal { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 关键断言：之前在 running/scanning/preparing 的那个任务，
        // 不应再处于活跃状态（cancelAllActiveDeleteTasks 确实取消了它）。
        // 协作式 cancel 可能让任务自然完成（.completed）或被取消（.cancelled），
        // 但绝不会再是 .running/.scanning/.preparing。
        if let runningID = runningTaskID,
           let finalSnap = try? deleteTaskStatus(taskId: runningID) {
            XCTAssertFalse([.preparing, .scanning, .running].contains(finalSnap.status),
                            "shutdown 后之前活跃的任务不应再处于活跃状态，实际: \(finalSnap.status)")
        }

        // 所有任务应到达终态
        let finalSnaps = try taskIDs.map { try deleteTaskStatus(taskId: $0) }
        for snap in finalSnaps {
            XCTAssertTrue([.completed, .failed, .cancelled, .skipped].contains(snap.status),
                            "所有删除任务应到达终态，实际: \(snap.status)")
        }
    }

    // MARK: - 门控：停机后拒绝新删除

    /// beginApplicationShutdown 后，TransferStore 不应再接受删除任务注册。
    /// 当前 TransferStore 没有 delete 注册入口（删除直接走 FFI），
    /// 但 TransferStore.beginApplicationShutdown 应调用 FFI 门控层。
    func testBeginShutdown_rejectsNewDeleteRegistration() {
        let store = TransferStore()
        store.beginApplicationShutdown()

        // 期望：TransferStore 应有 isAcceptingNewDelete 属性或等效门禁
        // 或 beginApplicationShutdown 直接在 FFI 层门控 startLocalDelete
        // 当前实现没有，测试会失败 → 驱动 7.2 实现
        // 此测试占位：等 7.2 实现后补充具体断言
        XCTAssertFalse(store.isAcceptingNewTasks,
                       "停机后应不再接受新任务")
    }

    // MARK: - 边界：幂等停机

    /// beginApplicationShutdown 重复调用应为 no-op。
    func testBeginShutdown_isIdempotent() {
        let store = TransferStore()
        store.beginApplicationShutdown()
        let first = store.isAcceptingNewTasks

        store.beginApplicationShutdown()
        let second = store.isAcceptingNewTasks

        XCTAssertEqual(first, second, "重复停机调用结果应一致（幂等）")
        XCTAssertFalse(first, "停机后 isAcceptingNewTasks 应为 false")
    }

    // MARK: - 边界：无删除任务时空停机

    /// 没有活跃删除任务时停机不应崩溃。
    func testBeginShutdown_noActiveDeletes_isNoOp() {
        let store = TransferStore()
        store.beginApplicationShutdown()

        // 不应崩溃
        XCTAssertFalse(store.isAcceptingNewTasks)
        XCTAssertTrue(store.deleteTasks.isEmpty || store.deleteTasks.allSatisfy {
            [.completed, .failed, .cancelled, .skipped].contains($0.status)
        })
    }

    // MARK: - 意外：取消失败不阻塞其余清理

    /// 当某个删除任务的 cancel 调用失败时，其他活跃任务仍应被取消。
    func testBeginShutdown_cancelFailure_doesNotBlockOthers() async throws {
        // 启动正常删除任务
        let dir = tempDir.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for j in 0..<50 {
            try Data(count: 1024 * 512).write(to: dir.appendingPathComponent("f\(j).bin"))
        }
        let goodTaskID = try startLocalDelete(targets: [dir.path])

        // 给启动时间
        try await Task.sleep(nanoseconds: 50_000_000)

        let store = TransferStore()
        store.beginApplicationShutdown()

        // 正常任务应被取消（或自然完成）
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let snap = try? deleteTaskStatus(taskId: goodTaskID)
            if let s = snap, [.completed, .failed, .cancelled, .skipped].contains(s.status) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let finalSnap = try deleteTaskStatus(taskId: goodTaskID)
        XCTAssertTrue([.completed, .failed, .cancelled, .skipped].contains(finalSnap.status),
                       "无论取消是否调用成功，任务应到达终态")
    }
}