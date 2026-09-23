import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 核心会话跟踪 FFI 集成测试：验证 Swift 通过 FFI 访问核心会话管理服务的正确性。
///
/// 核心代次语义：未注册会话的隐式代次为 0；`cancelSession` 将代次递增。
/// `isSessionStale` 在传入代次 != 当前代次时返回 true。
///
/// 覆盖三类场景：
/// - 正常：会话取消、代次过期查询、活跃句柄查询
/// - 意外：空字符串、极大代次值
/// - 边界：并发取消、并发查询、不同会话隔离
@MainActor
final class CoreSessionTrackingTests: XCTestCase {

    // MARK: - 正常流程

    /// 未注册会话的隐式代次为 0：代次 0 不过期，代次 1 过期。
    func testUnregisteredSessionDefaultGeneration() {
        let sessionID = "unregistered-\(UUID().uuidString)"
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 1))
    }

    /// 未注册会话不应有活跃句柄（无论代次）。
    func testUnregisteredSessionHasNoActive() {
        let sessionID = "unregistered-\(UUID().uuidString)"
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: 1))
    }

    /// 取消将会话代次从 0 递增到 1：代次 0 变为过期，代次 1 不过期。
    func testCancelIncrementsGeneration() {
        let sessionID = "cancel-gen-\(UUID().uuidString)"
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 1))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: 1))
    }

    /// 重复取消持续递增代次。
    func testRepeatedCancelIncrementsEachTime() {
        let sessionID = "repeat-cancel-\(UUID().uuidString)"
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 1))
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 1))
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 2))
    }

    /// 不同会话 ID 的代次管理相互独立。
    func testDifferentSessionsAreIsolated() {
        let sessionA = "isolated-a-\(UUID().uuidString)"
        let sessionB = "isolated-b-\(UUID().uuidString)"
        PandaCoreBridge.shared.cancelSession(sessionID: sessionA)
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionA, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionB, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionA, generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionB, generation: 0))
    }

    // MARK: - 意外操作

    /// 空字符串会话 ID 不应崩溃，行为与其他未注册会话一致。
    func testEmptySessionIDDoesNotCrash() {
        PandaCoreBridge.shared.cancelSession(sessionID: "")
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: "", generation: 0))
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: "", generation: 1))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: "", generation: 0))
    }

    /// 极大代次值不应溢出或崩溃。
    func testExtremeGenerationValues() {
        let sessionID = "extreme-\(UUID().uuidString)"
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: UInt32.max))
        XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: UInt32.max))
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
    }

    // MARK: - 边界条件

    /// 未注册会话代次 0 不过期；代次 >= 1 均过期。
    func testMultipleGenerationsForSameSession() {
        let sessionID = "multi-gen-\(UUID().uuidString)"
        XCTAssertFalse(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
        for gen: UInt32 in 1..<10 {
            XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: gen))
            XCTAssertFalse(PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: gen))
        }
    }

    /// 并发取消同一会话不应崩溃（线程安全）。
    func testConcurrentCancelDoesNotCrash() async throws {
        let sessionID = "concurrent-\(UUID().uuidString)"
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { [sessionID] in
                    PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
                }
            }
        }
        XCTAssertTrue(PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0))
    }

    /// 并发查询不同会话的代次状态不应互相干扰。
    func testConcurrentQueriesAcrossSessions() async throws {
        let sessions = (0..<10).map { "concurrent-query-\($0)-\(UUID().uuidString)" }
        await withTaskGroup(of: Void.self) { group in
            for sessionID in sessions {
                group.addTask { [sessionID] in
                    PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
                    let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: 0)
                    let active = PandaCoreBridge.shared.hasActiveSession(sessionID: sessionID, generation: 0)
                    XCTAssertTrue(stale)
                    XCTAssertFalse(active)
                }
            }
        }
    }
}
