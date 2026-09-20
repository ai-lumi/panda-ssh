import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 资源加载与 LocalizedTextResolver 查询路径测试
/// （OpenSpec 变更 add-app-internationalization 任务 2.1 / 2.2a / 2.2b / 2.3）。
///
/// 覆盖：正常中英显式查找（Localizable 与 Messages 两个 table）、
/// 意外漏打包/缺译文/参数类型不符、边界未知键/空参数/0-1-2-大数量复数/
/// 单位临界值/特殊字符参数；并验证在非目标系统语言下仍可显式选择指定语言
/// （两个语言的字符串都被逐字断言，任一走系统语言即失败）。
final class LocalizationResourceTests: XCTestCase {

    // MARK: - 正常流程

    func testExplicitLanguageLookupFromLocalizableTable() {
        let resolver = LocalizedTextResolver.shared
        XCTAssertEqual(
            resolver.string(forKey: "settings.language.title", table: .localizable, language: .zhHans),
            "语言")
        XCTAssertEqual(
            resolver.string(forKey: "settings.language.title", table: .localizable, language: .en),
            "Language")
    }

    func testExplicitLanguageLookupFromMessagesTable() {
        let resolver = LocalizedTextResolver.shared
        XCTAssertEqual(
            resolver.string(forKey: "error.auth_failed", table: .messages, language: .zhHans),
            "认证失败")
        XCTAssertEqual(
            resolver.string(forKey: "error.auth_failed", table: .messages, language: .en),
            "Authentication failed")
    }

    /// 双向断言两语言结果不同且各自逐字正确，
    /// 证明查找不依赖宿主系统语言（含相反系统语言场景）。
    func testExplicitSelectionIsIndependentOfSystemLanguage() {
        let resolver = LocalizedTextResolver.shared
        let zh = resolver.string(forKey: "settings.language.title", table: .localizable, language: .zhHans)
        let en = resolver.string(forKey: "settings.language.title", table: .localizable, language: .en)
        XCTAssertEqual(zh, "语言")
        XCTAssertEqual(en, "Language")
        XCTAssertNotEqual(zh, en)
    }

    // MARK: - 意外操作（漏打包 / 缺译文 / 未知键）

    /// 模拟漏打包：自建无任何 lproj 的 Bundle，两级查找都未命中时
    /// 返回内置简体中文通用错误，不得崩溃或显示资源键。
    func testMissingPackagedLocalizationsReturnsBuiltinGenericError() throws {
        let dir = try makeTempDirectory()
        let bundle = try XCTUnwrap(Bundle(path: dir))
        let result = LocalizedTextResolver.shared.string(
            forKey: "settings.language.title", table: .localizable, language: .en, bundle: bundle)
        XCTAssertEqual(result, LocalizedTextResolver.builtinGenericError)
    }

    /// 模拟缺译文：目标语言 lproj 存在但缺键，回退到 zh-Hans 同键译文。
    func testMissingTranslationFallsBackToChinese() throws {
        let dir = try makeTempDirectory()
        writeStringsFile(dir: dir, language: "en", table: "Localizable",
                         entries: ["settings.language.title": "Language"])
        // zh-Hans lproj 故意不含该键的英文版所对应场景之外的键：
        writeStringsFile(dir: dir, language: "zh-Hans", table: "Localizable",
                         entries: ["app.test.zh_only": "仅中文"])
        let bundle = try XCTUnwrap(Bundle(path: dir))
        // en 存在 → 直接命中
        XCTAssertEqual(LocalizedTextResolver.shared.string(
            forKey: "settings.language.title", table: .localizable, language: .en, bundle: bundle),
            "Language")
        // en 缺键 → 回退 zh-Hans
        XCTAssertEqual(LocalizedTextResolver.shared.string(
            forKey: "app.test.zh_only", table: .localizable, language: .en, bundle: bundle),
            "仅中文")
    }

    /// 未知键：两语言都未命中 → 内置通用错误，不泄露资源键。
    func testUnknownKeyReturnsBuiltinGenericError() {
        let result = LocalizedTextResolver.shared.string(
            forKey: "app.test.definitely_missing", table: .localizable, language: .en)
        XCTAssertEqual(result, LocalizedTextResolver.builtinGenericError)
    }

    /// 未知键带参数：同样返回内置通用错误。
    func testUnknownKeyWithArgumentsReturnsBuiltinGenericError() {
        let result = LocalizedTextResolver.shared.string(
            forKey: "app.test.definitely_missing", table: .localizable, language: .zhHans,
            arguments: [42])
        XCTAssertEqual(result, LocalizedTextResolver.builtinGenericError)
    }

    // MARK: - 边界（空参数 / 特殊字符参数）

    func testEmptyArgumentsOnPlainTemplate() {
        let result = LocalizedTextResolver.shared.string(
            forKey: "settings.language.title", table: .localizable, language: .zhHans,
            arguments: [])
        XCTAssertEqual(result, "语言")
    }

    /// 参数包含百分号/引号/花括号/换行时不被二次解释为格式模板或资源键。
    func testSpecialCharactersInParameterAreNotReinterpreted() {
        let weird = "%s %@ \"quoted\" {brace}\nnewline %lld"
        let result = LocalizedTextResolver.shared.string(
            forKey: "app.test.echo.label", table: .localizable, language: .en,
            arguments: [weird])
        XCTAssertEqual(result, "echo: %s %@ \"quoted\" {brace}\nnewline %lld")
    }

    // MARK: - 数量复数（stringsdict 变体路径，任务 2.2b / 2.3）

    func testPluralVariantsInEnglish() {
        let resolver = LocalizedTextResolver.shared
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .en, arguments: [0]),
            "0 files")
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .en, arguments: [1]),
            "1 file")
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .en, arguments: [2]),
            "2 files")
        // 大数量断言对数字分组不敏感：localizedStringWithFormat 按 Locale.current
        // 呈现数字（en_US 为 "1,000,000"），此处验证的是复数 other 变体被触发。
        let large = resolver.string(forKey: "transfer.files.count", table: .localizable, language: .en, arguments: [1_000_000])
        XCTAssertTrue(large.hasSuffix("files"), "英语大数量应使用复数 other 变体：\(large)")
        XCTAssertTrue(large.contains("1000000") || large.contains("1,000,000"), "英语大数量应包含数字：\(large)")
    }

    func testPluralVariantsInChinese() {
        let resolver = LocalizedTextResolver.shared
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .zhHans, arguments: [0]),
            "共 0 个文件")
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .zhHans, arguments: [1]),
            "共 1 个文件")
        XCTAssertEqual(
            resolver.string(forKey: "transfer.files.count", table: .localizable, language: .zhHans, arguments: [2]),
            "共 2 个文件")
        let large = resolver.string(forKey: "transfer.files.count", table: .localizable, language: .zhHans, arguments: [1_000_000])
        XCTAssertTrue(large.hasSuffix("个文件"), "中文大数量应使用复数模板：\(large)")
        XCTAssertTrue(large.contains("1000000") || large.contains("1,000,000"), "中文大数量应包含数字：\(large)")
    }

    // MARK: - 动态 descriptor 路径（任务 2.2b）

    /// descriptor 参数名/数量/kind 校验通过时按位置组装模板。
    func testDescriptorFormatsWithPositionalParameters() {
        let descriptor = MessageDescriptor(
            code: "error.host_key_mismatch",
            parameters: [
                MessageParameter(name: "host", kind: .string, stringValue: "srv1.example.com",
                                 intValue: nil, uintValue: nil, boolValue: nil),
                MessageParameter(name: "presented_fingerprint", kind: .string,
                                 stringValue: "SHA256:present", intValue: nil, uintValue: nil, boolValue: nil),
                MessageParameter(name: "stored_fingerprint", kind: .string,
                                 stringValue: "SHA256:stored", intValue: nil, uintValue: nil, boolValue: nil),
            ],
            technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .zhHans),
            "「srv1.example.com」的主机密钥已变更：已记录 SHA256:stored，当前出示 SHA256:present。")
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .en),
            "The host key of srv1.example.com has changed: recorded SHA256:stored, presented SHA256:present.")
    }

    /// kind 与模板占位符不符 → 通用错误资源，不显示占位符。
    func testDescriptorKindMismatchReturnsGenericError() {
        let descriptor = MessageDescriptor(
            code: "error.host_key_mismatch",
            parameters: [
                MessageParameter(name: "host", kind: .int, stringValue: nil,
                                 intValue: 42, uintValue: nil, boolValue: nil),
                MessageParameter(name: "presented_fingerprint", kind: .string,
                                 stringValue: "SHA256:present", intValue: nil, uintValue: nil, boolValue: nil),
                MessageParameter(name: "stored_fingerprint", kind: .string,
                                 stringValue: "SHA256:stored", intValue: nil, uintValue: nil, boolValue: nil),
            ],
            technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .zhHans),
            LocalizedTextResolver.builtinGenericError)
    }

    /// 参数数量与模板不符 → 通用错误资源。
    func testDescriptorParameterCountMismatchReturnsGenericError() {
        let descriptor = MessageDescriptor(
            code: "error.host_key_mismatch",
            parameters: [
                MessageParameter(name: "host", kind: .string, stringValue: "srv1",
                                 intValue: nil, uintValue: nil, boolValue: nil),
            ],
            technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .en),
            LocalizedTextResolver.builtinGenericError)
    }

    /// 重复参数名 → 通用错误资源。
    func testDescriptorDuplicateParameterNamesReturnGenericError() {
        let param = MessageParameter(name: "host", kind: .string, stringValue: "a",
                                     intValue: nil, uintValue: nil, boolValue: nil)
        let descriptor = MessageDescriptor(code: "error.host_key_mismatch",
                                           parameters: [param, param], technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .zhHans),
            LocalizedTextResolver.builtinGenericError)
    }

    /// 未按名称升序的参数 → 通用错误资源（wire 契约要求升序）。
    func testDescriptorUnsortedParametersReturnGenericError() {
        let host = MessageParameter(name: "host", kind: .string, stringValue: "srv1",
                                    intValue: nil, uintValue: nil, boolValue: nil)
        let stored = MessageParameter(name: "stored_fingerprint", kind: .string,
                                      stringValue: "SHA256:stored", intValue: nil, uintValue: nil, boolValue: nil)
        let presented = MessageParameter(name: "presented_fingerprint", kind: .string,
                                         stringValue: "SHA256:present", intValue: nil, uintValue: nil, boolValue: nil)
        // stored > presented，但按 stored, presented, host 传入 → 非升序。
        let descriptor = MessageDescriptor(code: "error.host_key_mismatch",
                                           parameters: [stored, presented, host], technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .zhHans),
            LocalizedTextResolver.builtinGenericError)
    }

    /// kind 与唯一值字段不一致 → 通用错误资源。
    func testDescriptorKindValueInconsistencyReturnsGenericError() {
        let descriptor = MessageDescriptor(
            code: "error.auth_failed",
            parameters: [
                MessageParameter(name: "user", kind: .int, stringValue: "not-an-int",
                                 intValue: nil, uintValue: nil, boolValue: nil),
            ],
            technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .zhHans),
            LocalizedTextResolver.builtinGenericError)
    }

    /// 未来/未知消息标识 → 通用错误资源，不崩溃、不显示原始 code。
    func testUnknownDescriptorCodeReturnsGenericError() {
        let descriptor = MessageDescriptor(code: "error.future_code_from_newer_schema",
                                           parameters: [], technicalDetail: nil)
        XCTAssertEqual(
            LocalizedTextResolver.shared.string(descriptor: descriptor, language: .en),
            LocalizedTextResolver.builtinGenericError)
    }

    // MARK: - 显示用时长格式化（任务 2.3 / 2.4）

    func testDurationFormattingInChinese() {
        XCTAssertEqual(DurationFormatter.localizedDuration(seconds: 0, language: .zhHans), "0秒")
        XCTAssertEqual(DurationFormatter.localizedDuration(seconds: 59, language: .zhHans), "59秒")
        XCTAssertEqual(DurationFormatter.localizedDuration(seconds: 60, language: .zhHans), "1分钟")
        XCTAssertEqual(DurationFormatter.localizedDuration(seconds: 61, language: .zhHans), "1分钟1秒")
        let hour = DurationFormatter.localizedDuration(seconds: 3661, language: .zhHans)
        XCTAssertEqual(hour, "1小时1分钟1秒")
    }

    func testDurationFormattingInEnglish() {
        let zero = DurationFormatter.localizedDuration(seconds: 0, language: .en)
        XCTAssertTrue(zero.contains("0"), "0 秒的英语显示应包含数字 0：\(zero)")
        let sixty = DurationFormatter.localizedDuration(seconds: 60, language: .en)
        XCTAssertTrue(sixty.contains("1") && (sixty.contains("min") || sixty.contains("m")),
                      "60 秒的英语显示应为 1 分钟：\(sixty)")
        let critical = DurationFormatter.localizedDuration(seconds: 61, language: .en)
        XCTAssertTrue(critical.contains("1"), "61 秒的英语显示应包含 1 分钟与 1 秒：\(critical)")
        let large = DurationFormatter.localizedDuration(seconds: 360_000, language: .en)
        XCTAssertTrue(large.contains("100") , "大数量的英语显示应包含 100 小时：\(large)")
    }

    /// 无效时长（nil / 负数）→ 未知时长资源，不崩溃。
    func testUnknownDurationReturnsLocalizedResource() {
        XCTAssertEqual(
            DurationFormatter.localizedDuration(seconds: nil, language: .zhHans),
            "未知时长")
        XCTAssertEqual(
            DurationFormatter.localizedDuration(seconds: -1, language: .zhHans),
            "未知时长")
        XCTAssertEqual(
            DurationFormatter.localizedDuration(seconds: nil, language: .en),
            "Unknown duration")
    }

    // MARK: - 测试辅助

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("panda-loc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if tempRoot != nil {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    /// 返回临时目录路径，并写入最小 Info.plist，使 Bundle(path:) 返回非 nil。
    private func makeTempDirectory() throws -> String {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleIdentifier</key>
            <string>com.pandassh.tests.localizationfixture</string>
        </dict>
        </plist>
        """
        try plist.write(to: tempRoot.appendingPathComponent("Info.plist"),
                        atomically: true, encoding: .utf8)
        return tempRoot.path
    }

    /// 在临时目录写入 xx.lproj/<table>.strings，模拟任意打包状态。
    private func writeStringsFile(dir: String, language: String, table: String,
                                  entries: [String: String]) {
        let lproj = URL(fileURLWithPath: dir).appendingPathComponent("\(language).lproj")
        try? FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let body = entries.map { "\"\($0.key)\" = \"\($0.value.replacingOccurrences(of: "\"", with: "\\\""))\";" }
            .joined(separator: "\n")
        try? body.write(to: lproj.appendingPathComponent("\(table).strings"),
                        atomically: true, encoding: .utf8)
    }
}
