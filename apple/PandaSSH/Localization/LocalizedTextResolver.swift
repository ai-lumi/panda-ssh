import Foundation

/// 应用支持的显式界面语言。
/// 「跟随系统」偏好模式（阶段 3）在呈现层解析后同样落到这两个有效语言。
enum AppLanguage: String, CaseIterable {
    case zhHans = "zh-Hans"
    case en = "en"
}

/// 资源表：Swift 来源文案 → Localizable，Rust/FFI message code 文案 → Messages。
enum LocalizationTable: String, CaseIterable {
    case localizable = "Localizable"
    case messages = "Messages"
}

/// 动态消息 descriptor 的单个参数（对应 Rust MessageDescriptorRecord wire schema v1，
/// 正式 FFI 绑定在任务 5.2 接入；本类型是 Swift 侧的呈现形状）。
struct MessageParameter {
    enum Kind: String {
        case string, int, uint, bool
    }

    let name: String
    let kind: Kind
    var stringValue: String?
    var intValue: Int64?
    var uintValue: UInt64?
    var boolValue: Bool?

    init(name: String, kind: Kind, stringValue: String? = nil, intValue: Int64? = nil,
         uintValue: UInt64? = nil, boolValue: Bool? = nil) {
        self.name = name
        self.kind = kind
        self.stringValue = stringValue
        self.intValue = intValue
        self.uintValue = uintValue
        self.boolValue = boolValue
    }

    /// wire 契约：kind 与唯一值字段一致才有效。
    var isConsistent: Bool {
        switch kind {
        case .string: return stringValue != nil && intValue == nil && uintValue == nil && boolValue == nil
        case .int: return intValue != nil && stringValue == nil && uintValue == nil && boolValue == nil
        case .uint: return uintValue != nil && stringValue == nil && intValue == nil && boolValue == nil
        case .bool: return boolValue != nil && stringValue == nil && intValue == nil && uintValue == nil
        }
    }

    /// 参数类别（用于与模板占位符类别做多重集比较）。
    var allowedSpecifierClass: MessageParameter.Kind {
        kind == .bool ? .string : kind
    }
}

/// 动态消息 descriptor（对应 Rust MessageDescriptorRecord wire schema v1）。
struct MessageDescriptor {
    let code: String
    let parameters: [MessageParameter]
    let technicalDetail: String?

    init(code: String, parameters: [MessageParameter], technicalDetail: String?) {
        self.code = code
        self.parameters = parameters
        self.technicalDetail = technicalDetail
    }
}

/// 资源查询入口（任务 2.2 / 2.2a / 2.2b）。
///
/// 固定查询路径：
/// 1. 以 `Bundle.preferredLocalizations(from:forPreferences:)` 匹配包内可用语言变体，
///    并显式校验语言主码一致（防止无匹配时 preferredLocalizations 仍返回候选值）。
/// 2. 经对应 `xx.lproj` 子 Bundle 的 `Bundle.localizedString(forKey:value:table:)` 查显式 table。
/// 3. 目标语言未命中 → 显式回退 `zh-Hans`。
/// 4. 两级查找都未命中 → `builtinGenericError`（内置简体中文通用错误，不查资源，保证任何资源状态下可用）。
///
/// 禁止使用带 `localizations:` 参数的 `Bundle.localizedString(forKey:value:table:localizations:)`，
/// 该 API 要求 macOS 15.4 / iOS 18.4，高于部署基线（macOS 14 / iPadOS 17）。
final class LocalizedTextResolver {
    static let shared = LocalizedTextResolver()

    /// 两级查找都未命中时的内置兜底文案（简体中文硬编码，保证任何资源状态下可用）。
    static let builtinGenericError = "操作未能完成，请重试。"

    private init() {}

    private static let missingSentinel = "\u{0}panda.missing\u{0}"
    /// 变参 splat 上限；descriptor 参数数一般 ≤ 5，超限按异常兜底。
    private static let maxSplatArguments = 10
    private static let specifierRegex = try! NSRegularExpression(
        pattern: "%(\\d+\\$)?(ll|l|z|h)?([@diouxXeEfgcsScC])")

    // MARK: - 公开 API

    /// 按显式语言查指定 table 的文案；支持参数插值（stringsdict 复数模板在此路径生效）。
    func string(forKey key: String, table: LocalizationTable, language: AppLanguage,
                arguments: [CVarArg] = [], bundle: Bundle = .main) -> String {
        guard let (template, lproj) = templateWithLproj(forKey: key, table: table, language: language, bundle: bundle) else {
            return Self.builtinGenericError
        }
        guard !arguments.isEmpty else { return template }
        return Self.format(template, arguments, lproj: lproj, table: table.rawValue, key: key)
    }

    /// 按 descriptor 查 Messages 表并按位置组装模板。任一校验失败 → 内置通用错误。
    func string(descriptor: MessageDescriptor, language: AppLanguage, bundle: Bundle = .main) -> String {
        guard Self.areValid(descriptor.parameters),
              let template = template(forKey: descriptor.code, table: .messages, language: language, bundle: bundle),
              let arguments = Self.formatArguments(for: descriptor.parameters, template: template)
        else { return Self.builtinGenericError }
        return Self.format(template, arguments)
    }

    // MARK: - 查询路径

    private func template(forKey key: String, table: LocalizationTable, language: AppLanguage,
                          bundle: Bundle) -> String? {
        return templateWithLproj(forKey: key, table: table, language: language, bundle: bundle)?.0
    }

    private func templateWithLproj(forKey key: String, table: LocalizationTable, language: AppLanguage,
                                   bundle: Bundle) -> (String, Bundle)? {
        // 使用 Bundle.main 查找，它会自动处理 .strings 和 .stringsdict
        // 通过 lproj 子 bundle 获取语言特定的资源路径
        guard let lproj = lprojBundle(for: language, in: bundle) else {
            // 回退 zh-Hans
            if language != .zhHans, let fallback = lprojBundle(for: .zhHans, in: bundle) {
                if let value = lookupWithStringsdict(forKey: key, table: table, in: fallback) {
                    return (value, fallback)
                }
            }
            return nil
        }
        if let value = lookupWithStringsdict(forKey: key, table: table, in: lproj) {
            return (value, lproj)
        }
        // 回退 zh-Hans
        if language != .zhHans, let fallback = lprojBundle(for: .zhHans, in: bundle) {
            if let value = lookupWithStringsdict(forKey: key, table: table, in: fallback) {
                return (value, fallback)
            }
        }
        return nil
    }

    /// 查找键：先查 .strings，miss 后查 .stringsdict 并手动展开复数规则。
    private func lookupWithStringsdict(forKey key: String, table: LocalizationTable, in lproj: Bundle) -> String? {
        // 先查 .strings
        let stringsValue = lproj.localizedString(forKey: key, value: Self.missingSentinel, table: table.rawValue)
        if stringsValue != Self.missingSentinel {
            return stringsValue
        }
        // .strings miss，尝试 .stringsdict
        guard let stringsdictPath = lproj.path(forResource: table.rawValue, ofType: "stringsdict"),
              let dict = NSDictionary(contentsOfFile: stringsdictPath) as? [String: Any],
              let entry = dict[key] as? [String: Any]
        else { return nil }
        // 返回 NSStringLocalizedFormatKey（如 "%#@value@"）
        return entry["NSStringLocalizedFormatKey"] as? String
    }

    /// 2.2a 固定路径：以 preferredLocalizations 匹配包内可用语言变体，
    /// 并显式校验语言主码一致，防止无匹配时 preferredLocalizations 仍返回候选值。
    private func lprojBundle(for language: AppLanguage, in bundle: Bundle) -> Bundle? {
        let expected = language.rawValue
        let candidates = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [expected])
        guard let match = candidates.first,
              let expectedCode = Locale(identifier: expected).language.languageCode?.identifier,
              let matchCode = Locale(identifier: match).language.languageCode?.identifier,
              expectedCode == matchCode,
              let path = bundle.path(forResource: match, ofType: "lproj"),
              let lproj = Bundle(path: path)
        else { return nil }
        return lproj
    }

    // MARK: - 格式化

    /// 变参 splat：Swift 变参不支持数组展开，按参数个数逐一展开到 localizedStringWithFormat。
    /// 对于复数模板（%#@var@），手动展开复数规则。
    private static func format(_ template: String, _ arguments: [CVarArg], lproj: Bundle? = nil, table: String? = nil, key: String? = nil) -> String {
        // 检测复数模板 %@#var@
        if template.contains("%#@") && template.contains("@") {
            // 手动展开复数规则
            if let expanded = expandPlural(template: template, arguments: arguments, lproj: lproj, table: table, key: key) {
                return expanded
            }
        }
        switch arguments.count {
        case 0: return template
        case 1: return String.localizedStringWithFormat(template, arguments[0])
        case 2: return String.localizedStringWithFormat(template, arguments[0], arguments[1])
        case 3: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2])
        case 4: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3])
        case 5: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
        case 6: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5])
        case 7: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6])
        case 8: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6], arguments[7])
        case 9: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6], arguments[7], arguments[8])
        case 10: return String.localizedStringWithFormat(template, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6], arguments[7], arguments[8], arguments[9])
        default: return builtinGenericError
        }
    }

    /// 手动展开复数规则：从 stringsdict 加载复数变体，根据参数值选择正确的变体。
    private static func expandPlural(template: String, arguments: [CVarArg], lproj: Bundle?, table: String?, key: String?) -> String? {
        guard let lproj = lproj, let table = table, let key = key,
              let stringsdictPath = lproj.path(forResource: table, ofType: "stringsdict"),
              let dict = NSDictionary(contentsOfFile: stringsdictPath) as? [String: Any],
              let entry = dict[key] as? [String: Any]
        else { return nil }

        // 查找复数变量（如 "value"）
        for (varName, varDict) in entry where varName != "NSStringLocalizedFormatKey" {
            guard let varInfo = varDict as? [String: Any],
                  varInfo["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType",
                  let valueType = varInfo["NSStringFormatValueTypeKey"] as? String
            else { continue }

            // 获取参数值（假设第一个参数是复数计数）
            guard let countArg = arguments.first else { return nil }
            let count: Int64
            if let intVal = countArg as? Int64 {
                count = intVal
            } else if let intVal = countArg as? Int {
                count = Int64(intVal)
            } else {
                return nil
            }

            // 选择复数变体（简化：只处理 one/other，英语规则）
            let variant: String
            if count == 1, let one = varInfo["one"] as? String {
                variant = one
            } else if let other = varInfo["other"] as? String {
                variant = other
            } else {
                return nil
            }

            // 替换模板中的变量引用（如 "%#@value@" → 实际值）
            let result = variant.replacingOccurrences(of: "%\(valueType)", with: "\(count)")
            return result
        }
        return nil
    }

    // MARK: - descriptor 校验

    private static func areValid(_ parameters: [MessageParameter]) -> Bool {
        for i in parameters.indices.dropFirst() where parameters[i - 1].name >= parameters[i].name {
            return false
        }
        return parameters.allSatisfy(\.isConsistent)
    }

    /// 校验模板占位符类别多重集与参数 kind 多重集一致；返回构造好的 CVarArg 数组。
    private static func formatArguments(for parameters: [MessageParameter], template: String) -> [CVarArg]? {
        guard let specifiers = extractSpecifierClasses(template),
              specifiers.count == parameters.count,
              multisetsEqual(specifiers, parameters.map(\.allowedSpecifierClass))
        else { return nil }
        return parameters.map { p in
            switch p.kind {
            case .string: return p.stringValue!
            case .int: return p.intValue!
            case .uint: return p.uintValue!
            case .bool: return p.boolValue! ? "true" : "false"
            }
        }
    }

    private static func multisetsEqual(_ a: [MessageParameter.Kind], _ b: [MessageParameter.Kind]) -> Bool {
        guard a.count == b.count else { return false }
        var counts: [MessageParameter.Kind: Int] = [:]
        for x in a { counts[x, default: 0] += 1 }
        for x in b { counts[x, default: 0] -= 1 }
        return counts.values.allSatisfy { $0 == 0 }
    }

    /// 提取模板中占位符类别序列；遇到不支持的转换字符（如浮点）整体返回 nil。
    private static func extractSpecifierClasses(_ template: String) -> [MessageParameter.Kind]? {
        let ns = template as NSString
        let matches = specifierRegex.matches(in: template, range: NSRange(location: 0, length: ns.length))
        var classes: [MessageParameter.Kind] = []
        for m in matches {
            let convRange = m.range(at: 3)
            guard convRange.location != NSNotFound,
                  convRange.location + convRange.length <= ns.length,
                  convRange.length > 0 else { return nil }
            let conv = ns.substring(with: convRange).first!
            guard let cls = specifierClass(conv) else { return nil }
            classes.append(cls)
        }
        return classes
    }

    private static func specifierClass(_ conversion: Character) -> MessageParameter.Kind? {
        switch conversion {
        case "@", "s", "S", "c", "C": return .string
        case "d", "i": return .int
        case "u", "x", "X", "o": return .uint
        default: return nil
        }
    }
}
