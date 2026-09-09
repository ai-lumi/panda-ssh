import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// 分栏 `setPosition` 幂等化判定纯函数测试：0.5pt 阈值语义。
/// 高频 SwiftUI 更新重复携带同值（或亚像素抖动）时不重设分栏位置，
/// 避免强制 NSSplitView 反复布局。
@MainActor
final class UnifiedSplitPositionPolicyTests: XCTestCase {
    // MARK: 正常流程

    func test宽度变化超过阈值时需要设置() {
        XCTAssertTrue(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 300, appliedWidth: 250
            )
        )
    }

    func test宽度与上次相同不需要设置() {
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250, appliedWidth: 250
            )
        )
    }

    // MARK: 意外操作

    func test无上次应用值时首次必须设置() {
        XCTAssertTrue(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250, appliedWidth: nil
            )
        )
    }

    func test候选值非有限数时不设置() {
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: .nan, appliedWidth: 250
            )
        )
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: .infinity, appliedWidth: nil
            )
        )
    }

    // MARK: 边界条件

    func test差值恰为阈值半像素时不设置() {
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250.5, appliedWidth: 250
            )
        )
    }

    func test差值超过阈值半像素时设置() {
        XCTAssertTrue(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250.6, appliedWidth: 250
            )
        )
    }

    /// 夹逼后往返场景：首次 250 设置；亚像素抖动 250.3 不重设；
    /// 累计超过阈值 250.6 重设并更新基准；回落 250.4（差 0.2）不再重设。
    func test亚像素往返抖动不触发重复设置() {
        XCTAssertTrue(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250, appliedWidth: nil
            )
        )
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250.3, appliedWidth: 250
            )
        )
        XCTAssertTrue(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250.6, appliedWidth: 250
            )
        )
        XCTAssertFalse(
            MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: 250.4, appliedWidth: 250.6
            )
        )
    }
}
#endif
