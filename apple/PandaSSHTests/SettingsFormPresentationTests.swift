import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 任务 8.5：设置表单呈现契约。
///
/// 这些测试固定用户可见的布局语义；输入值的解析和范围校验仍由 Rust FFI 覆盖。
final class SettingsFormPresentationTests: XCTestCase {
    func test终端缓冲区只显示一条辅助说明() {
        XCTAssertEqual(
            SettingsFormContract.terminalBufferHelperText,
            "范围 1000 ～ 100000"
        )
        XCTAssertEqual(SettingsFormContract.terminalBufferInputPrompt, "")
        XCTAssertEqual(
            SettingsFormContract.terminalBufferAccessibilityLabel,
            "缓冲区高度（行）"
        )
        XCTAssertTrue(SettingsFormContract.terminalBufferUsesSingleFormRow)
        XCTAssertTrue(SettingsFormContract.terminalBufferHelperAlignsWithInput)
    }

    func test终端缓冲区使用数字编辑控件() {
        XCTAssertFalse(SettingsFormContract.terminalBufferUsesStepper)
        XCTAssertTrue(SettingsFormContract.terminalBufferHasDecrementButton)
        XCTAssertTrue(SettingsFormContract.terminalBufferHasIncrementButton)
        #if os(iOS)
        XCTAssertTrue(SettingsFormContract.terminalBufferUsesNumberPad)
        #endif
    }

    func test显式设置操作统一使用末端对齐() {
        XCTAssertEqual(
            SettingsFormContract.explicitActionAlignment,
            .trailing
        )
    }
}
