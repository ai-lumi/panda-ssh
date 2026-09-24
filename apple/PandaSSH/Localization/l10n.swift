import Foundation

/// 资源键查找入口，匹配审计受控模式 `l10n.str/text/count("key")`。
/// 运行时解析当前语言，经 `LocalizedTextResolver` 查表返回已本地化文案。
enum l10n {
    static var currentLanguage: AppLanguage {
        let preferred = Bundle.preferredLocalizations(
            from: AppLanguage.allCases.map(\.rawValue),
            forPreferences: Locale.preferredLanguages
        )
        return preferred.first.flatMap { AppLanguage(rawValue: $0) } ?? .zhHans
    }

    static func str(_ key: String) -> String {
        LocalizedTextResolver.shared.string(
            forKey: key, table: .localizable, language: currentLanguage)
    }

    static func text(_ key: String) -> String {
        str(key)
    }

    static func count(_ key: String, _ count: Int) -> String {
        LocalizedTextResolver.shared.string(
            forKey: key, table: .localizable, language: currentLanguage,
            arguments: [count])
    }
}
