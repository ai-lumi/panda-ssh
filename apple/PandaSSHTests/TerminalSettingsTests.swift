import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 任务 8.3：Swift 侧缓冲区设置持久化测试。
///
/// 正常：FFI 返回的规范化整数写入 UserDefaults；
/// 意外：非法或损坏的 UserDefaults 原始值经 FFI 回退默认值且不崩溃；
/// 边界：缺失值回退默认值、保存后立即读取一致。
final class TerminalSettingsTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let key = "terminal.bufferLines.raw"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: key)
    }

    override func tearDown() {
        defaults.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - 正常流程

    func test缺失值回退默认值() {
        let settings = TerminalSettings.shared
        XCTAssertEqual(settings.bufferLines(), defaultTerminalBufferLines())
    }

    func test缺失值原始文本回退默认值字符串() {
        let settings = TerminalSettings.shared
        XCTAssertEqual(settings.rawBufferLines(), String(defaultTerminalBufferLines()))
    }

    func test保存有效值后可读回() throws {
        let settings = TerminalSettings.shared
        try settings.saveBufferLines(raw: "5000")
        XCTAssertEqual(settings.bufferLines(), 5000)
        XCTAssertEqual(settings.rawBufferLines(), "5000")
    }

    func test保存边界最小值() throws {
        let settings = TerminalSettings.shared
        try settings.saveBufferLines(raw: "1000")
        XCTAssertEqual(settings.bufferLines(), 1000)
    }

    func test保存边界最大值() throws {
        let settings = TerminalSettings.shared
        try settings.saveBufferLines(raw: "100000")
        XCTAssertEqual(settings.bufferLines(), 100000)
    }

    func test保存默认值() throws {
        let settings = TerminalSettings.shared
        let defaultVal = defaultTerminalBufferLines()
        try settings.saveBufferLines(raw: String(defaultVal))
        XCTAssertEqual(settings.bufferLines(), defaultVal)
    }

    // MARK: - 意外流程

    func test保存非数字被拒绝() {
        let settings = TerminalSettings.shared
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "abc"))
    }

    func test保存空字符串回退默认值() throws {
        let settings = TerminalSettings.shared
        try settings.saveBufferLines(raw: "")
        XCTAssertEqual(settings.bufferLines(), defaultTerminalBufferLines())
    }

    func test保存超出上限被拒绝() {
        let settings = TerminalSettings.shared
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "100001"))
    }

    func test保存低于下限被拒绝() {
        let settings = TerminalSettings.shared
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "999"))
    }

    func test保存负数被拒绝() {
        let settings = TerminalSettings.shared
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "-1"))
    }

    func test保存零被拒绝() {
        let settings = TerminalSettings.shared
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "0"))
    }

    // MARK: - 边界条件

    func test损坏的UserDefaults值回退默认值() {
        defaults.set("not-a-number", forKey: key)
        let settings = TerminalSettings.shared
        XCTAssertEqual(settings.bufferLines(), defaultTerminalBufferLines())
    }

    func test保存失败不覆盖已有值() throws {
        let settings = TerminalSettings.shared
        try settings.saveBufferLines(raw: "5000")
        XCTAssertThrowsError(try settings.saveBufferLines(raw: "invalid"))
        XCTAssertEqual(settings.bufferLines(), 5000)
    }

    func test原始文本回显损坏值() {
        defaults.set("garbage", forKey: key)
        let settings = TerminalSettings.shared
        XCTAssertEqual(settings.rawBufferLines(), "garbage")
    }
}
