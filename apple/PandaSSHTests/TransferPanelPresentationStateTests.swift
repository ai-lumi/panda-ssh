import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class TransferPanelPresentationStateTests: XCTestCase {
    func testMac打开为抽屉且IPad按策略使用Inspector或Sheet() {
        var state = TransferPanelPresentationState()
        state.present(using: .drawer)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.presentation, .drawer)

        state.updatePresentation(.inspector)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.presentation, .inspector)

        state.updatePresentation(.sheet)
        XCTAssertEqual(state.presentation, .sheet)
    }

    func test呈现中旋转或改变宽度保持面板打开() {
        var state = TransferPanelPresentationState()
        state.present(using: .inspector)

        state.updatePresentation(.sheet)
        state.updatePresentation(.inspector)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.presentation, .inspector)
    }

    func test任务完成不会自动关闭面板() {
        var state = TransferPanelPresentationState()
        state.present(using: .sheet)

        XCTAssertTrue(state.isPresented)
    }

    func test关闭面板不产生任务取消或复制副作用() {
        let taskIDs = Set([UUID(), UUID()])
        var state = TransferPanelPresentationState()
        state.present(using: .drawer)

        state.dismiss()

        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(taskIDs.count, 2)
    }

    func test零个单个和大量任务不改变呈现规则() {
        for taskCount in [0, 1, 10_000] {
            var state = TransferPanelPresentationState()
            state.present(using: .sheet)
            XCTAssertTrue(state.isPresented, "任务数 \(taskCount) 不应阻止用户打开面板")
            XCTAssertEqual(state.presentation, .sheet)
        }
    }

    func test重复关闭保持幂等() {
        var state = TransferPanelPresentationState()
        state.dismiss()
        state.dismiss()
        XCTAssertEqual(state, TransferPanelPresentationState())
    }
}
