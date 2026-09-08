import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class TerminalContentPresentationTests: XCTestCase {
    func test画布尺寸归一化且状态面板不超过可用宽度() {
        let narrow = TerminalContentPresentation.resolve(phase: .failed, width: 120, height: 80)
        XCTAssertEqual(narrow.canvasWidth, 120)
        XCTAssertEqual(narrow.panelWidth, 88)
        let invalid = TerminalContentPresentation.resolve(phase: .shell, width: .nan, height: -1)
        XCTAssertEqual(invalid.canvasWidth, 0)
        XCTAssertEqual(invalid.canvasHeight, 0)
        XCTAssertFalse(invalid.requestsTerminalResize)
    }
    func test各阶段都占满画布且仅Shell拥有终端尺寸() {
        let connecting = TerminalContentPresentation.resolve(phase: .connecting, width: 900, height: 600)
        let shell = TerminalContentPresentation.resolve(phase: .shell, width: 900, height: 600)
        let failed = TerminalContentPresentation.resolve(phase: .failed, width: 900, height: 600)

        XCTAssertTrue(connecting.fillsCanvas)
        XCTAssertEqual(connecting.overlay, .centered)
        XCTAssertFalse(connecting.requestsTerminalResize)
        XCTAssertTrue(shell.fillsCanvas)
        XCTAssertEqual(shell.overlay, .none)
        XCTAssertTrue(shell.requestsTerminalResize)
        XCTAssertEqual(failed.overlay, .centered)
        XCTAssertFalse(failed.requestsTerminalResize)
    }

    func test缩放或侧栏显隐对应的零和极端尺寸不改变阶段所有权() {
        for size in [(0.0, 0.0), (Double.nan, 120.0), (4_096.0, 8_192.0)] {
            let connecting = TerminalContentPresentation.resolve(phase: .connecting, width: size.0, height: size.1)
            let shell = TerminalContentPresentation.resolve(phase: .shell, width: size.0, height: size.1)
            let failed = TerminalContentPresentation.resolve(phase: .failed, width: size.0, height: size.1)

            XCTAssertEqual(connecting.overlay, .centered)
            XCTAssertEqual(failed.overlay, .centered)
            XCTAssertEqual(shell.requestsTerminalResize, size.0.isFinite && size.0 > 0 && size.1 > 0)
        }
    }
}
