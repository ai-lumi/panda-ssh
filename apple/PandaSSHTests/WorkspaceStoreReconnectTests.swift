import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// `WorkspaceStore.reconnectTerminal(tabID:)` 默认注册表转发路径测试。
///
/// 覆盖 spec「终端内容区右键上下文菜单 → 执行重连」的转发行为：
/// 默认 `reconnectHandler`（读 `terminalSessions` 注册表 → `session.retry()`）
/// 在以下三类场景下的表现。区别于 `WorkspaceStoreTests` 中走注入闭包的用例，
/// 本文件验证**默认路径**——即真实 `TerminalSessionStore` 经 `registerTerminal`
/// 注册后，`reconnectTerminal` 能正确转发到 `session.retry()`。
/// - 正常流程：注册终端会话后调 reconnectTerminal → session.retry() 被调用。
/// - 意外操作：传不存在的 tabID / SFTP 标签 → 不抛异常、不调用任何 session。
/// - 边界条件：tabID 存在但 session 已释放（weak 引用 nil）/ 从未注册 → 不抛异常。
@MainActor
final class WorkspaceStoreReconnectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }


    /// 构造一个不注入 `reconnectHandler` 的 store，使用默认注册表转发路径。
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { _ in "web" })
    }

    /// 构造一个未连接的 `TerminalSessionStore`（`pendingRecord` 为 nil，
    /// 调 `retry()` 只更新 `attempt`/`phase`，不会触发异步 `connect()` Task）。
    private func makeSession() -> TerminalSessionStore {
        let host = HostEntry(
            id: "h1", name: "web", address: "example.com",
            port: 22, username: "root"
        )
        return TerminalSessionStore(host: host)
    }

    // MARK: - 正常流程

    /// §6.1 正常流程：注册 session 后调 reconnectTerminal → session.retry() 被调用。
    /// 通过观察副作用（`attempt` +1、`phase` 保持 .connecting）验证 retry() 执行。
    func testReconnectTerminal_callsRegisteredSessionRetry() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let tabID = store.tabs[0].id
        let session = makeSession()
        store.registerTerminal(session, for: tabID)
        XCTAssertEqual(session.attempt, 0, "初始 attempt 应为 0")

        store.reconnectTerminal(tabID: tabID)

        XCTAssertEqual(session.attempt, 1, "retry() 应使 attempt +1")
        XCTAssertEqual(session.phase, .connecting, "retry() 应将 phase 置为 .connecting")
    }

    // MARK: - 意外操作

    /// §6.1 意外操作：传不存在的 tabID（不在 tabs 中）→ 不抛异常、不调用任何已注册 session。
    func testReconnectTerminal_unknownTabID_isNoOp() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let realID = store.tabs[0].id
        let session = makeSession()
        store.registerTerminal(session, for: realID)

        // 传一个不存在的 tabID，不应崩溃、不应触发已注册 session 的 retry
        store.reconnectTerminal(tabID: UUID())

        XCTAssertEqual(session.attempt, 0, "不存在的 tabID 不应触发任何 session 的 retry")
    }

    /// SFTP 标签也从页签操作请求重连，而不是由内容区重复提供入口。
    func testReconnectSession_sftpTab_callsRegisteredSessionRequest() {
        let store = makeStore()
        store.openSFTP(hostID: "h1")
        let tabID = store.tabs[0].id
        let session = SftpSessionStore(host: HostEntry(
            id: "h1", name: "web", address: "example.com", port: 22, username: "root"
        ), transfers: TransferStore())
        var requests = 0
        session.onReconnectRequested = { requests += 1 }
        store.registerSftp(session, for: tabID)

        store.reconnectSession(tabID: tabID)

        XCTAssertEqual(requests, 1)
    }

    // MARK: - 边界条件

    /// §6.1 边界条件：tabID 存在于 tabs，但从未注册 session → 不抛异常。
    func testReconnectTerminal_neverRegisteredSession_isNoOp() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let tabID = store.tabs[0].id
        // 不调用 registerTerminal，terminalSessions[tabID] 为 nil

        store.reconnectTerminal(tabID: tabID)

        // 不崩溃即通过；标签仍存在
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// §6.1 边界条件：tabID 存在但 session 已释放（weak 引用 nil）→ 不抛异常。
    /// 模拟：注册一个 session 后不再持有强引用，对象释放后 weak 引用变 nil。
    func testReconnectTerminal_deallocatedSession_doesNotCrash() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let tabID = store.tabs[0].id
        // 注册一个临时 session，调用后不再持有强引用 → weak 引用变 nil
        store.registerTerminal(makeSession(), for: tabID)

        // 调用不应崩溃（weak .value 为 nil 时短路）
        store.reconnectTerminal(tabID: tabID)

        XCTAssertEqual(store.tabs.count, 1, "标签应仍存在")
    }
}
