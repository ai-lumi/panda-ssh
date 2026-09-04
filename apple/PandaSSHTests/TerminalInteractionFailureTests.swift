import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class TerminalInteractionFailureTests: XCTestCase {
    private final class WriteFailingConnection: ShellConnection {
        enum Failure: Error { case closed }
        func write(_ data: Data) throws { throw Failure.closed }
        func read(max: UInt64) throws -> Data { Data() }
        func resize(cols: UInt64, rows: UInt64) throws {}
        func close() throws {}
    }

    func testShellInputFailureImmediatelyMarksTerminalUnavailable() {
        var failureCount = 0
        let coordinator = TerminalCoordinator { failureCount += 1 }
        coordinator.update(connection: WriteFailingConnection())

        coordinator.sendToShell(Data("x".utf8))

        XCTAssertEqual(failureCount, 1)
        coordinator.detach()
    }

    func testEmptyInputOnMissingConnectionIsSafe() {
        var failureCount = 0
        let coordinator = TerminalCoordinator { failureCount += 1 }
        coordinator.sendToShell(Data())
        XCTAssertEqual(failureCount, 0)
    }
}
