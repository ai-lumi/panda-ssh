import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 传输任务状态机测试:覆盖正常流程(入队/进度/完成)、意外操作
/// (取消/重试/对终态任务操作)、边界条件(并发上限、空列表清除)三类用例。
/// 进度由测试直接调用 tick 驱动,不睡时钟。
@MainActor
final class TransferStoreTests: XCTestCase {

    /// 固定随机源(恒 0):速度 = max(64KB, size/40),失败点 = size 的 30%。
    /// 默认 failRule 为「永不失败」;需要演示失败语义的用例显式传规则或直接构造。
    private func makeStore(failRule: @escaping (Int) -> Bool = { _ in false }) -> TransferStore {
        TransferStore(failRule: failRule, random: { 0 })
    }

    @discardableResult
    private func addFile(_ store: TransferStore, name: String = "f.bin", size: UInt64 = 1_000_000) -> UUID {
        store.add(direction: .upload, name: name, size: size, source: "/l/\(name)", destination: "/r/\(name)")
    }

    /// 连续 tick 直到没有 running 任务或达到步数上限。
    private func drain(_ store: TransferStore, maxTicks: Int = 10_000) {
        var ticks = 0
        while store.tasks.contains(where: { $0.status == .running }), ticks < maxTicks {
            store.tick()
            ticks += 1
        }
    }

    // MARK: - 正常流程:入队 / 进度 / 完成

    func testAddTaskStartsRunningUnderLimit() {
        let store = makeStore()
        let id = addFile(store)

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .running)
        XCTAssertEqual(task?.direction, .upload)
        XCTAssertEqual(task?.name, "f.bin")
        XCTAssertEqual(task?.size, 1_000_000)
        XCTAssertEqual(task?.transferred, 0)
    }

    /// 应用进入停机后必须拒绝新的传输注册，且不能把占位 id 当作真实任务展示。
    func testBeginApplicationShutdown_rejectsNewTransfer() {
        let store = makeStore()
        _ = addFile(store, name: "before.bin")
        let batchID = store.addBatchUpload(sources: ["/l/tree"], destDir: "/r")

        store.beginApplicationShutdown()
        let rejected = addFile(store, name: "after.bin")

        XCTAssertFalse(store.isAcceptingNewTasks)
        XCTAssertNil(store.tasks.first { $0.id == rejected })
        XCTAssertTrue(store.tasks.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(store.tasks.first { $0.id == batchID }?.status, .cancelled)
    }

    func testTickAdvancesProgress() {
        let store = makeStore()
        let id = addFile(store)

        store.tick()

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .running)
        XCTAssertGreaterThan(task?.transferred ?? 0, 0)
        XCTAssertLessThan(task?.transferred ?? 0, 1_000_000)
    }

    func testTaskCompletesWhenTransferredReachesSize() {
        let store = makeStore()
        let id = addFile(store, size: 10_000) // 速度 64KB/s,两次 tick 内完成

        drain(store)

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .done)
        XCTAssertEqual(task?.transferred, task?.size)
    }

    // MARK: - 并发上限与排队补位

    func testFourthTaskQueuesWhenThreeRunning() {
        let store = makeStore()
        let ids = (0..<4).map { addFile(store, name: "f\($0)") }

        XCTAssertEqual(store.tasks.filter { $0.status == .running }.count, 3)
        XCTAssertEqual(store.tasks.first { $0.id == ids[3] }?.status, .queued)
    }

    func testQueuedTaskPromotedWhenRunningCompletes() {
        let store = makeStore()
        _ = addFile(store, name: "a", size: 10_000)
        _ = addFile(store, name: "b", size: 10_000)
        _ = addFile(store, name: "c", size: 10_000)
        let queued = addFile(store, name: "d", size: 10_000)

        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .done)
        XCTAssertEqual(store.tasks.filter { $0.status == .done }.count, 4)
    }

    func testActiveCountCoversRunningAndQueued() {
        let store = makeStore()
        (0..<5).forEach { addFile(store, name: "f\($0)") }

        XCTAssertEqual(store.activeCount, 5)
    }

    // MARK: - 暂停与继续

    func testPauseRunningTaskStopsProgress() {
        let store = makeStore()
        let id = addFile(store)
        store.tick()
        let before = store.tasks.first { $0.id == id }?.transferred ?? 0
        XCTAssertGreaterThan(before, 0)

        store.pause(id: id)
        store.tick()
        store.tick()

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .paused)
        XCTAssertEqual(task?.transferred, before, "暂停后进度应冻结")
    }

    func testResumePausedTaskContinues() {
        let store = makeStore()
        let id = addFile(store)
        store.tick()
        store.pause(id: id)
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .paused)

        store.resume(id: id)
        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .done)
    }

    func testPauseQueuedTaskDoesNotAcquireSlot() {
        let store = makeStore()
        (0..<3).forEach { addFile(store, name: "f\($0)", size: 10_000_000) }
        let queued = addFile(store, name: "q")
        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .queued)

        store.pause(id: queued)
        // 取消前三个任务让出槽位,被暂停的排队任务不应被提升。
        store.tasks.filter { $0.status == .running }.forEach { store.cancel(id: $0.id) }
        store.tick()

        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .paused)

        store.resume(id: queued)
        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .done)
    }

    func testCancelPausedTask() {
        let store = makeStore()
        let id = addFile(store)
        store.pause(id: id)
        store.cancel(id: id)

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .cancelled)
    }

    func testResumedTaskSpeedIsNotDilutedByPauseInterval() {
        // 固定随机源使速度可预测：size=10_000_000 / (40+0.5*80) = 125_000 bytes/s。
        let store = TransferStore(random: { 0.5 })
        let id = addFile(store, name: "f", size: 10_000_000)
        store.tick()
        store.tick()
        let before = store.tasks.first { $0.id == id }!
        XCTAssertGreaterThan(before.liveSpeed, 100_000)

        store.pause(id: id)
        store.tick()
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .paused)

        // 暂停 1 秒；若窗口未重置，旧采样点会把实时速度稀释到接近 0。
        Thread.sleep(forTimeInterval: 1.0)

        store.resume(id: id)
        store.tick()

        let after = store.tasks.first { $0.id == id }!
        XCTAssertEqual(after.status, .running)
        XCTAssertGreaterThan(after.liveSpeed, 50_000, "继续后速度应恢复，不应被暂停时间稀释")
    }

    func testResumeThroughQueuedStateStillResetsSpeedWindow() {
        let store = makeStore()
        // 占满 3 个并发槽位，让第四个任务处于 queued。
        (0..<3).forEach { addFile(store, name: "blocker\($0)", size: 10_000_000) }
        let id = addFile(store, name: "paused", size: 10_000_000)
        store.tick()
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .queued)

        store.pause(id: id)
        store.tick()
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .paused)

        // FFI resume 后任务先回到 Queued，等槽位释放才 Running。
        store.resume(id: id)
        store.tick()
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .queued)

        let blocker = store.tasks.first { $0.name == "blocker0" }!
        store.cancel(id: blocker.id)
        store.tick()

        let task = store.tasks.first { $0.id == id }!
        XCTAssertEqual(task.status, .running)
        XCTAssertGreaterThan(task.liveSpeed, 0, "经 Queued 恢复后也应能显示实时速度")
    }

    // MARK: - 演示失败:前两个必成功,此后按规则失败

    func testFirstTwoTasksNeverFailEvenWithAggressiveRandom() {
        let store = TransferStore(random: { 0 }) // 默认规则:random<1/3 即失败
        _ = addFile(store, name: "a")
        _ = addFile(store, name: "b")

        XCTAssertNil(store.tasks[0].failAt)
        XCTAssertNil(store.tasks[1].failAt)
    }

    func testLaterTasksMayFailByRule() {
        let store = TransferStore(random: { 0.1 }) // 0.1 < 1/3 → 第三个起必失败
        _ = addFile(store, name: "a", size: 10_000)
        _ = addFile(store, name: "b", size: 10_000)
        let third = addFile(store, name: "c", size: 10_000)

        XCTAssertNotNil(store.tasks.first { $0.id == third }?.failAt)
    }

    func testRunningTaskFailsAtFailPointAndQueuedPromoted() {
        let store = makeStore(failRule: { $0 == 0 }) // 第一个任务必失败
        let failing = addFile(store, name: "bad", size: 1_000_000)
        _ = addFile(store, name: "ok1")
        _ = addFile(store, name: "ok2")
        let queued = addFile(store, name: "next")

        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == failing }?.status, .failed)
        // 失败让出并发槽,排队任务被补位执行(恒 0 随机源下不再失败)
        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .done)
    }

    // MARK: - 取消

    func testCancelRunningTask() {
        let store = makeStore()
        let id = addFile(store)

        store.cancel(id: id)

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .cancelled)
    }

    func testCancelQueuedTaskNeverGetsScheduled() {
        let store = makeStore()
        (0..<3).forEach { addFile(store, name: "f\($0)", size: 10_000) }
        let queued = addFile(store, name: "q", size: 10_000)

        store.cancel(id: queued)
        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == queued }?.transferred, 0)
    }

    func testCancelRunningPromotesQueued() {
        let store = makeStore()
        let running = addFile(store, name: "a")
        _ = addFile(store, name: "b")
        _ = addFile(store, name: "c")
        let queued = addFile(store, name: "d")

        store.cancel(id: running)

        XCTAssertEqual(store.tasks.first { $0.id == queued }?.status, .running)
    }

    // MARK: - 重试

    func testRetryFailedTaskRequeuesAndSucceeds() {
        let store = makeStore(failRule: { $0 == 0 })
        let failing = addFile(store, name: "bad", size: 10_000)
        drain(store)
        XCTAssertEqual(store.tasks.first { $0.id == failing }?.status, .failed)

        store.retry(id: failing)
        drain(store)

        let task = store.tasks.first { $0.id == failing }
        XCTAssertEqual(task?.status, .done)
        XCTAssertEqual(task?.transferred, task?.size)
    }

    // MARK: - 清除已完成

    func testClearFinishedKeepsActiveTasks() {
        // 恒 0 随机源:速度 64KB/s → 10KB 文件两次 tick 完成;
        // 第四个任务(d)按规则在 30% 处失败;c 是 100MB 大文件,始终保持 running。
        let store = makeStore(failRule: { $0 == 3 })
        _ = addFile(store, name: "a", size: 10_000)
        _ = addFile(store, name: "b", size: 10_000)
        let running = addFile(store, name: "c", size: 100_000_000)
        let doomed = addFile(store, name: "d", size: 10_000)

        store.tick() // a/b/c 推进
        store.tick() // a/b 完成,d 补位
        store.tick() // d 越过失败点 → failed

        XCTAssertEqual(store.tasks.first { $0.id == doomed }?.status, .failed)
        XCTAssertEqual(store.tasks.first { $0.id == running }?.status, .running)

        store.clearFinished()

        // 只保留进行中/排队任务(c),已完成与失败的一并清除(与原型一致)
        XCTAssertEqual(store.tasks.map(\.id), [running])
        XCTAssertEqual(store.tasks.first?.status, .running)
    }

    func testClearFinishedOnEmptyListIsNoOp() {
        let store = makeStore()
        store.clearFinished()
        XCTAssertTrue(store.tasks.isEmpty)
    }

    // MARK: - 意外操作:对不存在的任务操作必须是 no-op

    func testOperationsOnUnknownIDAreNoOp() {
        let store = makeStore()
        let id = addFile(store)

        store.cancel(id: UUID())
        store.retry(id: UUID())

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .running)
    }

    func testCancelTerminalStateTaskIsNoOp() {
        let store = makeStore()
        let id = addFile(store, size: 10_000)
        drain(store)
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .done)

        store.cancel(id: id)

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .done)
    }

    func testRetryNonFailedTaskIsNoOp() {
        let store = makeStore()
        let id = addFile(store)

        store.retry(id: id)

        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .running)
    }

    // MARK: - 路径映射

    func testUploadMapsSourceToLocalAndDestinationToRemote() {
        let spy = TransferSourceSpy()
        let store = TransferStore(source: spy)

        _ = store.add(
            direction: .upload,
            name: "f.bin",
            size: 100,
            source: "/local/f.bin",
            destination: "/remote/f.bin"
        )

        XCTAssertEqual(spy.calls.last?.localPath, "/local/f.bin")
        XCTAssertEqual(spy.calls.last?.remotePath, "/remote/f.bin")
        XCTAssertEqual(spy.calls.last?.size, 100)
    }

    func testDownloadMapsDestinationToLocalAndSourceToRemote() {
        let spy = TransferSourceSpy()
        let store = TransferStore(source: spy)

        _ = store.add(
            direction: .download,
            name: "f.bin",
            size: 100,
            source: "/remote/f.bin",
            destination: "/local/f.bin"
        )

        XCTAssertEqual(spy.calls.last?.localPath, "/local/f.bin")
        XCTAssertEqual(spy.calls.last?.remotePath, "/remote/f.bin")
        XCTAssertEqual(spy.calls.last?.size, 100)
    }

    // MARK: - 速度展示

    func testRunningTaskHasPositiveLiveAndTotalSpeed() {
        let store = makeStore()
        let id = addFile(store, size: 10_000_000)

        store.tick() // 推进一次，产生进度变化

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .running)
        XCTAssertGreaterThan(task?.liveSpeed ?? 0, 0)
        XCTAssertGreaterThan(task?.totalSpeed ?? 0, 0)
        XCTAssertNotNil(task?.estimatedTimeRemaining)
    }

    func testCompletedTaskHasZeroLiveSpeedAndNoEstimatedRemaining() {
        let store = makeStore()
        let id = addFile(store, size: 10_000)

        drain(store)

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .done)
        XCTAssertEqual(task?.liveSpeed, 0)
        XCTAssertGreaterThanOrEqual(task?.totalSpeed ?? 0, 0)
        XCTAssertNil(task?.estimatedTimeRemaining)
    }

    func testCancelledTaskHasZeroLiveSpeed() {
        let store = makeStore()
        let id = addFile(store)

        store.tick()
        store.cancel(id: id)

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .cancelled)
        XCTAssertEqual(task?.liveSpeed, 0)
        XCTAssertNil(task?.estimatedTimeRemaining)
    }

    func testQueuedTaskHasZeroSpeed() {
        let store = makeStore()
        (0..<3).forEach { addFile(store, name: "f\($0)") }
        let queued = addFile(store, name: "q")

        let task = store.tasks.first { $0.id == queued }
        XCTAssertEqual(task?.status, .queued)
        XCTAssertEqual(task?.liveSpeed, 0)
        XCTAssertEqual(task?.totalSpeed, 0)
        XCTAssertNil(task?.estimatedTimeRemaining)
    }

    func testSpeedIsPreservedAcrossRefresh() {
        let store = makeStore()
        let id = addFile(store, size: 10_000_000)
        store.tick()
        let before = store.tasks.first { $0.id == id }
        XCTAssertGreaterThan(before?.liveSpeed ?? 0, 0)

        // add 另一个任务触发 refresh，原任务速度不应丢失
        _ = addFile(store, name: "other", size: 1_000_000)

        let after = store.tasks.first { $0.id == id }
        XCTAssertEqual(after?.totalSpeed, before?.totalSpeed)
    }

    // MARK: - 批量任务

    func testAddBatchUploadRecordsSourcesAndDestDir() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)

        let id = store.addBatchUpload(sources: ["/local/a.txt", "/local/b.txt"], destDir: "/remote/dir", hostID: "h1")

        XCTAssertEqual(spy.uploads.last?.sources, ["/local/a.txt", "/local/b.txt"])
        XCTAssertEqual(spy.uploads.last?.destDir, "/remote/dir")
        XCTAssertEqual(spy.uploads.last?.hostID, "h1")
        let task = store.tasks.first { $0.id == id }
        XCTAssertTrue(task?.isBatch ?? false)
        XCTAssertEqual(task?.batchSources, ["/local/a.txt", "/local/b.txt"])
        XCTAssertEqual(task?.batchDestDir, "/remote/dir")
    }

    func testBatchTaskNameShowsCount() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)

        store.addBatchUpload(sources: ["/tmp/a.txt", "/tmp/b.txt"], destDir: "/r")

        let task = store.tasks.first
        XCTAssertEqual(task?.name, "a.txt 等 2 项")
    }

    func testBatchTaskProgressReflectsRecord() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)
        let id = store.addBatchUpload(sources: ["/tmp/a.bin"], destDir: "/r")

        spy.setBatchTask(id: id, totalSize: 1_000, transferred: 400, status: .running)
        store.tick()

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .running)
        XCTAssertEqual(task?.size, 1_000)
        XCTAssertEqual(task?.transferred, 400)
        XCTAssertEqual(task?.percent, 40)
    }

    func testCancelBatchTaskCallsBatchCancel() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)
        let id = store.addBatchUpload(sources: ["/tmp/a.bin"], destDir: "/r")

        store.cancel(id: id)

        XCTAssertTrue(spy.cancelledIDs.contains(id.uuidString))
    }

    func testBatchTaskCompletedWhenRecordDone() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)
        let id = store.addBatchUpload(sources: ["/tmp/a.bin"], destDir: "/r")

        spy.setBatchTask(id: id, totalSize: 500, transferred: 500, status: .done)
        store.tick()

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.status, .done)
        XCTAssertEqual(task?.progress, 1)
    }

    func testBatchTaskWaitingForConflictCarriesConflictAndStaysQueued() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)
        let id = store.addBatchUpload(sources: ["/tmp/a.txt"], destDir: "/r")

        let conflict = PendingConflict(
            name: "a.txt",
            sourceSize: 100,
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            targetSize: 200,
            targetDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        spy.setBatchTask(id: id, totalSize: 100, transferred: 0, status: .queued, pendingConflict: conflict)
        store.tick()

        let task = store.tasks.first { $0.id == id }
        // 等待覆盖确认的批量任务在 UI 状态机中呈现为排队（等待徽标）。
        XCTAssertEqual(task?.status, .queued)
        XCTAssertEqual(task?.pendingConflict, conflict)
    }

    func testBatchTaskConflictClearedAfterResolve() {
        let spy = BatchTransferSourceSpy()
        let store = TransferStore(source: spy, batchSource: spy)
        let id = store.addBatchUpload(sources: ["/tmp/a.txt"], destDir: "/r")

        let conflict = PendingConflict(
            name: "a.txt",
            sourceSize: 100,
            sourceDate: nil,
            targetSize: 200,
            targetDate: nil
        )
        spy.setBatchTask(id: id, totalSize: 100, transferred: 0, status: .queued, pendingConflict: conflict)
        store.tick()
        XCTAssertNotNil(store.tasks.first { $0.id == id }?.pendingConflict)

        // Rust 决策后 pending_conflict 置空，任务继续（模拟 running）。
        spy.setBatchTask(id: id, totalSize: 100, transferred: 0, status: .running, pendingConflict: nil)
        store.tick()
        XCTAssertNil(store.tasks.first { $0.id == id }?.pendingConflict)
        XCTAssertEqual(store.tasks.first { $0.id == id }?.status, .running)
    }

    // MARK: - 任务组

    func testGroupedTasksAggregateIntoTaskGroup() {
        let store = makeStore()
        let groupID = UUID()
        let groupName = "project"
        let id1 = store.add(direction: .upload, name: "a.swift", size: 100, source: "/l/a.swift", destination: "/r/a.swift", groupID: groupID, groupName: groupName)
        let id2 = store.add(direction: .upload, name: "b.swift", size: 200, source: "/l/b.swift", destination: "/r/b.swift", groupID: groupID, groupName: groupName)
        let id3 = store.add(direction: .upload, name: "c.swift", size: 300, source: "/l/c.swift", destination: "/r/c.swift")

        let groups = store.taskGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, groupID)
        XCTAssertEqual(groups.first?.name, groupName)
        XCTAssertEqual(groups.first?.tasks.count, 2)
        XCTAssertTrue(groups.first?.tasks.contains(where: { $0.id == id1 }) == true)
        XCTAssertTrue(groups.first?.tasks.contains(where: { $0.id == id2 }) == true)
        XCTAssertEqual(store.tasks.first { $0.id == id3 }?.groupID, nil)
    }

    func testTaskGroupProgressReflectsMemberProgress() {
        let store = makeStore()
        let groupID = UUID()
        _ = store.add(direction: .upload, name: "a.bin", size: 1_000_000, source: "/l/a.bin", destination: "/r/a.bin", groupID: groupID, groupName: "g")
        _ = store.add(direction: .upload, name: "b.bin", size: 2_000_000, source: "/l/b.bin", destination: "/r/b.bin", groupID: groupID, groupName: "g")

        store.tick()

        let group = store.taskGroups.first { $0.id == groupID }
        XCTAssertEqual(group?.totalSize, 3_000_000)
        XCTAssertGreaterThan(group?.transferred ?? 0, 0)
        XCTAssertGreaterThan(group?.progress ?? 0, 0)
        XCTAssertLessThan(group?.progress ?? 1, 1)
    }

    func testCancelGroupStopsAllMembers() {
        let store = makeStore()
        let groupID = UUID()
        let id1 = store.add(direction: .upload, name: "a.bin", size: 1_000_000, source: "/l/a.bin", destination: "/r/a.bin", groupID: groupID, groupName: "g")
        let id2 = store.add(direction: .upload, name: "b.bin", size: 1_000_000, source: "/l/b.bin", destination: "/r/b.bin", groupID: groupID, groupName: "g")
        let id3 = store.add(direction: .upload, name: "c.bin", size: 1_000_000, source: "/l/c.bin", destination: "/r/c.bin")

        store.cancelGroup(id: groupID)

        XCTAssertEqual(store.tasks.first { $0.id == id1 }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == id2 }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == id3 }?.status, .running)
    }

    func testRetryGroupOnlyRetriesFailedMembers() {
        let store = makeStore(failRule: { $0 == 1 }) // 第二个任务(b)失败
        let groupID = UUID()
        let id1 = store.add(direction: .upload, name: "a.bin", size: 10_000, source: "/l/a.bin", destination: "/r/a.bin", groupID: groupID, groupName: "g")
        let id2 = store.add(direction: .upload, name: "b.bin", size: 10_000, source: "/l/b.bin", destination: "/r/b.bin", groupID: groupID, groupName: "g")
        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == id2 }?.status, .failed)

        store.retryGroup(id: groupID)
        drain(store)

        XCTAssertEqual(store.tasks.first { $0.id == id1 }?.status, .done)
        XCTAssertEqual(store.tasks.first { $0.id == id2 }?.status, .done)
    }

    func testGroupRegistryPreservesGroupAfterRefresh() {
        let store = makeStore()
        let groupID = UUID()
        let groupName = "docs"
        let id = store.add(direction: .upload, name: "a.txt", size: 100, source: "/l/a.txt", destination: "/r/a.txt", groupID: groupID, groupName: groupName)

        // add 另一个任务触发 refresh
        _ = store.add(direction: .upload, name: "b.txt", size: 100, source: "/l/b.txt", destination: "/r/b.txt")

        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.groupID, groupID)
        XCTAssertEqual(task?.groupName, groupName)
    }

    // MARK: - 按主机取消(删除主机级联)

    func testCancelAllForHostCancelsOnlyThatHost() {
        let store = makeStore()
        let h1a = store.add(direction: .upload, name: "a", size: 10_000_000, source: "/l/a", destination: "/r/a", hostID: "h1")
        let h1b = store.add(direction: .upload, name: "b", size: 10_000_000, source: "/l/b", destination: "/r/b", hostID: "h1")
        let h2 = store.add(direction: .upload, name: "c", size: 10_000_000, source: "/l/c", destination: "/r/c", hostID: "h2")
        // 第四个任务排队(并发上限 3),仍属活跃集合
        let h1c = store.add(direction: .upload, name: "d", size: 10_000_000, source: "/l/d", destination: "/r/d", hostID: "h1")

        store.cancelAll(forHostID: "h1")

        XCTAssertEqual(store.tasks.first { $0.id == h1a }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == h1b }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == h1c }?.status, .cancelled)
        XCTAssertEqual(store.tasks.first { $0.id == h2 }?.status, .running)
    }

    func testCancelAllForHostSkipsTerminalTasks() {
        let store = makeStore()
        let done = store.add(direction: .upload, name: "a", size: 10_000, source: "/l/a", destination: "/r/a", hostID: "h1")
        drain(store)
        XCTAssertEqual(store.tasks.first { $0.id == done }?.status, .done)

        store.cancelAll(forHostID: "h1")

        // 终态任务不被重复取消
        XCTAssertEqual(store.tasks.first { $0.id == done }?.status, .done)
    }

}

/// 记录 enqueueTransfer 参数,用于验证 upload/download 路径映射。
private final class TransferSourceSpy: TransferSource {
    struct Call {
        let direction: TransferDirection
        let hostID: String
        let localPath: String
        let remotePath: String
        let size: UInt64
    }

    var calls: [Call] = []

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
        calls.append(Call(direction: direction, hostID: hostID, localPath: localPath, remotePath: remotePath, size: size))
        return UUID().uuidString
    }

    func cancelTransfer(id: String) {}
    func pauseTransfer(id: String) {}
    func resumeTransfer(id: String) {}
    func retryTransfer(id: String) -> String { UUID().uuidString }
    func listTransfers() -> [TransferRecord] { [] }
    func tick() {}
}

/// 批量传输源 spy,用于验证 Swift 侧批量任务映射与生命周期。
private final class BatchTransferSourceSpy: TransferSource, BatchTransferSource {
    var revision: UInt64? = nil
    var listReads = 0
    var afterList: (() -> Void)?
    func changeRevision() -> UInt64? { revision }

    struct BatchCall {
        let hostID: String
        let sources: [String]
        let destDir: String
    }

    var uploads: [BatchCall] = []
    var downloads: [BatchCall] = []
    var cancelledIDs: Set<String> = []
    private var tasks: [BatchTransferRecord] = []
    private var nextID = 1

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
        UUID().uuidString
    }

    func cancelTransfer(id: String) {}
    func pauseTransfer(id: String) {}
    func resumeTransfer(id: String) {}
    func retryTransfer(id: String) -> String { UUID().uuidString }
    func listTransfers() -> [TransferRecord] { [] }
    func tick() {}

    func enqueueBatchUpload(
        hostID: String,
        sources: [String],
        destDir: String,
        groupID: String?,
        groupName: String?,
        password: String?,
        passphrase: String?
    ) -> String {
        let id = makeID()
        uploads.append(BatchCall(hostID: hostID, sources: sources, destDir: destDir))
        tasks.append(makeRecord(id: id, direction: .upload, sources: sources, destDir: destDir, groupID: groupID.flatMap { UUID(uuidString: $0) }, groupName: groupName))
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
        let id = makeID()
        downloads.append(BatchCall(hostID: hostID, sources: sources, destDir: destDir))
        tasks.append(makeRecord(id: id, direction: .download, sources: sources, destDir: destDir, groupID: groupID.flatMap { UUID(uuidString: $0) }, groupName: groupName))
        return id
    }

    func cancelBatchTransfer(id: String) {
        cancelledIDs.insert(id)
        guard let index = tasks.firstIndex(where: { $0.id.uuidString == id }) else { return }
        if tasks[index].status == .running || tasks[index].status == .queued {
            tasks[index] = mutated(tasks[index], status: .cancelled)
        }
    }

    func listBatchTransfers() -> [BatchTransferRecord] {
        listReads += 1
        let result = tasks
        afterList?()
        return result
    }

    func setBatchTask(id: UUID, totalSize: UInt64, transferred: UInt64, status: TransferStatus, pendingConflict: PendingConflict? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index] = BatchTransferRecord(
            id: id,
            direction: tasks[index].direction,
            name: tasks[index].name,
            size: totalSize,
            transferred: transferred,
            status: status,
            sources: tasks[index].sources,
            destDir: tasks[index].destDir,
            hostID: tasks[index].hostID,
            error: nil,
            pendingConflict: pendingConflict,
            groupID: tasks[index].groupID,
            groupName: tasks[index].groupName
        )
    }

    private func makeID() -> String {
        nextID += 1
        return UUID().uuidString
    }

    private func makeRecord(id: String, direction: TransferDirection, sources: [String], destDir: String, groupID: UUID? = nil, groupName: String? = nil) -> BatchTransferRecord {
        BatchTransferRecord(
            id: UUID(uuidString: id) ?? UUID(),
            direction: direction,
            name: "",
            size: 0,
            transferred: 0,
            status: .queued,
            sources: sources,
            destDir: destDir,
            hostID: "",
            error: nil,
            pendingConflict: nil,
            groupID: groupID,
            groupName: groupName
        )
    }

    private func mutated(_ record: BatchTransferRecord, status: TransferStatus) -> BatchTransferRecord {
        BatchTransferRecord(
            id: record.id,
            direction: record.direction,
            name: record.name,
            size: record.size,
            transferred: record.transferred,
            status: status,
            sources: record.sources,
            destDir: record.destDir,
            hostID: record.hostID,
            error: record.error,
            pendingConflict: record.pendingConflict,
            groupID: record.groupID,
            groupName: record.groupName
        )
    }
}

@MainActor
final class TransferTaskPresentationTests: XCTestCase {
    private func task(direction: TransferDirection = .upload, size: UInt64 = 100,
                      status: TransferStatus = .running, batch: Bool = false) -> TransferTask {
        TransferTask(record: TransferRecord(
            id: UUID(), direction: direction, name: "中文 文件", size: size,
            transferred: 0, status: status, source: "/源/中文 文件", destination: "/目标/中文 文件",
            hostID: "host-id", error: nil, version: 0, failAt: nil, isBatch: batch,
            batchSources: ["/源/a", "/源/b"], batchDestDir: "/目标",
            groupID: nil, groupName: nil, pendingConflict: nil))
    }

    func test上传下载端点与路径完整保留() {
        for direction in [TransferDirection.upload, .download] {
            let value = task(direction: direction)
            let display = TransferTaskPresentation(task: value, hostName: "服务器")
            XCTAssertEqual(display.sourceEndpoint, direction == .upload ? "本地" : "服务器")
            XCTAssertEqual(display.destinationEndpoint, direction == .upload ? "服务器" : "本地")
            XCTAssertEqual(display.sourcePath, value.source)
            XCTAssertEqual(display.destinationPath, value.destination)
        }
    }

    func test缺失主机和批量路径() {
        for hostName: String? in [nil, "", "  "] {
            let display = TransferTaskPresentation(task: task(batch: true), hostName: hostName)
            XCTAssertEqual(display.destinationEndpoint, "host-id")
            XCTAssertEqual(display.sourcePath, "/源/a\n/源/b")
            XCTAssertEqual(display.destinationPath, "/目标")
        }
    }

    func test零字节仅完成状态展示完成进度() {
        for status in [TransferStatus.queued, .running, .paused, .failed, .cancelled, .done] {
            let display = TransferTaskPresentation(task: task(size: 0, status: status), hostName: nil)
            XCTAssertEqual(display.progress, status == .done ? 1 : nil)
        }
    }

    func test停止任务不显示陈旧速度() {
        for status in [TransferStatus.queued, .running, .paused, .failed, .cancelled, .done] {
            var value = task(status: status)
            value.liveSpeed = 512
            let display = TransferTaskPresentation(task: value, hostName: nil)
            XCTAssertEqual(display.liveSpeed, status == .running ? 512 : 0)
        }
    }

    func test长路径不丢失且进度不越界() {
        var value = task(size: 1)
        value.transferred = UInt64.max
        XCTAssertEqual(TransferTaskPresentation(task: value, hostName: nil).progress, 1)
        let longName = String(repeating: "中文", count: 2000)
        XCTAssertEqual(TransferTaskPresentation(task: value, hostName: longName).destinationEndpoint, longName)
    }
}


@MainActor
final class TaskRevisionTests: XCTestCase {
    func test不变修订跳过快照并持续读取新的字节进度() {
        let source = BatchTransferSourceSpy()
        source.revision = 1
        let store = TransferStore(source: source, batchSource: source)
        let id = store.addBatchUpload(sources: ["/fixture/a"], destDir: "/remote")
        let reads = source.listReads
        store.tick()
        XCTAssertEqual(source.listReads, reads)
        for count: UInt64 in [1, 50, 100] {
            source.setBatchTask(id: id, totalSize: 100, transferred: count, status: .running)
            source.revision! += 1
            store.tick()
            XCTAssertEqual(store.tasks.first?.transferred, count)
        }
    }

    func test读取快照期间更新留给下一拍() {
        let source = BatchTransferSourceSpy()
        source.revision = 1
        let store = TransferStore(source: source, batchSource: source)
        let id = store.addBatchUpload(sources: ["/fixture/a"], destDir: "/remote")
        source.afterList = {
            source.afterList = nil
            source.setBatchTask(id: id, totalSize: 100, transferred: 70, status: .running)
            source.revision! += 1
        }
        // add 的主动刷新也必须在读取列表之前捕获修订。
        _ = store.addBatchUpload(sources: ["/fixture/b"], destDir: "/remote")
        store.tick()
        XCTAssertEqual(store.tasks.first { $0.id == id }?.transferred, 70)
    }

    func test等待冲突与失败仅依赖注入源修订() {
        let source = BatchTransferSourceSpy()
        source.revision = 1
        let store = TransferStore(source: source, batchSource: source)
        let id = store.addBatchUpload(sources: ["/fixture/a"], destDir: "/remote")
        let conflict = PendingConflict(name: "a", sourceSize: 10, sourceDate: nil, targetSize: 5, targetDate: nil)
        source.setBatchTask(id: id, totalSize: 10, transferred: 0, status: .queued, pendingConflict: conflict)
        source.revision! += 1
        store.tick()
        XCTAssertEqual(store.tasks.first?.pendingConflict, conflict)
        source.setBatchTask(id: id, totalSize: 10, transferred: 1, status: .failed)
        source.revision! += 1
        store.tick()
        XCTAssertEqual(store.tasks.first?.status, .failed)
    }
}
