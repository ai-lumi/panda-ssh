import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 页签键盘快捷键切换的索引计算逻辑测试：覆盖正常流程（中间页签切换）、
/// 边界条件（首尾循环）、意外操作（空列表、单页签、无效索引）三类用例。
final class TabSwitchIndexTests: XCTestCase {

    // MARK: - nextTabIndex 测试

    /// 正常流程：中间页签切换到下一个
    func testNextTabIndex_middleTab_advancesToNext() {
        XCTAssertEqual(nextTabIndex(current: 0, total: 3), 1)
        XCTAssertEqual(nextTabIndex(current: 1, total: 3), 2)
    }

    /// 边界条件：最后一个页签循环到第一个
    func testNextTabIndex_lastTab_wrapsToFirst() {
        XCTAssertEqual(nextTabIndex(current: 2, total: 3), 0)
    }

    /// 边界条件：单页签时返回自身
    func testNextTabIndex_singleTab_returnsSelf() {
        XCTAssertEqual(nextTabIndex(current: 0, total: 1), 0)
    }

    /// 意外操作：空页签列表返回 nil
    func testNextTabIndex_emptyTabs_returnsNil() {
        XCTAssertNil(nextTabIndex(current: 0, total: 0))
    }

    /// 意外操作：负数索引返回 nil
    func testNextTabIndex_negativeIndex_returnsNil() {
        XCTAssertNil(nextTabIndex(current: -1, total: 3))
    }

    /// 意外操作：索引超出范围返回 nil
    func testNextTabIndex_outOfRangeIndex_returnsNil() {
        XCTAssertNil(nextTabIndex(current: 5, total: 3))
        XCTAssertNil(nextTabIndex(current: 3, total: 3))
    }

    // MARK: - previousTabIndex 测试

    /// 正常流程：中间页签切换到上一个
    func testPreviousTabIndex_middleTab_movesToPrevious() {
        XCTAssertEqual(previousTabIndex(current: 2, total: 3), 1)
        XCTAssertEqual(previousTabIndex(current: 1, total: 3), 0)
    }

    /// 边界条件：第一个页签循环到最后一个
    func testPreviousTabIndex_firstTab_wrapsToLast() {
        XCTAssertEqual(previousTabIndex(current: 0, total: 3), 2)
    }

    /// 边界条件：单页签时返回自身
    func testPreviousTabIndex_singleTab_returnsSelf() {
        XCTAssertEqual(previousTabIndex(current: 0, total: 1), 0)
    }

    /// 意外操作：空页签列表返回 nil
    func testPreviousTabIndex_emptyTabs_returnsNil() {
        XCTAssertNil(previousTabIndex(current: 0, total: 0))
    }

    /// 意外操作：负数索引返回 nil
    func testPreviousTabIndex_negativeIndex_returnsNil() {
        XCTAssertNil(previousTabIndex(current: -1, total: 3))
    }

    /// 意外操作：索引超出范围返回 nil
    func testPreviousTabIndex_outOfRangeIndex_returnsNil() {
        XCTAssertNil(previousTabIndex(current: 5, total: 3))
        XCTAssertNil(previousTabIndex(current: 3, total: 3))
    }
}
