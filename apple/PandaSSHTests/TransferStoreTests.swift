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
}
