import Foundation

/// 显示用时长格式化（任务 2.3 / 2.4）。
///
/// 设计要点：
/// - 单位标签走资源 catalog（`transfer.duration.{hour,minute,second}.unit`），
///   数值与单位拼接走资源模板 `transfer.duration.amount.label`（`%lld%@`）。
/// - 不使用 `DateComponentsFormatter`：它无显式 locale 属性且 `Locale.current` 在当前 SDK 不可写，
///   输出会跟随运行环境系统语言，无法在显式语言选择下保证逐字正确。
/// - 零值与未知时长走独立资源键。
enum DurationFormatter {
    static func localizedDuration(seconds: Int64?, language: AppLanguage,
                                  bundle: Bundle = .main) -> String {
        let resolver = LocalizedTextResolver.shared
        guard let seconds, seconds >= 0 else {
            return resolver.string(forKey: "transfer.duration.unknown.message",
                                   table: .localizable, language: language, bundle: bundle)
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        guard h > 0 || m > 0 || s > 0 else {
            return resolver.string(forKey: "transfer.duration.zero.message",
                                   table: .localizable, language: language, bundle: bundle)
        }
        var parts: [String] = []
        if h > 0 { parts.append(amountLabel(h, unitKey: "transfer.duration.hour.unit", language: language, bundle: bundle)) }
        if m > 0 { parts.append(amountLabel(m, unitKey: "transfer.duration.minute.unit", language: language, bundle: bundle)) }
        if s > 0 { parts.append(amountLabel(s, unitKey: "transfer.duration.second.unit", language: language, bundle: bundle)) }
        // 中文无分隔，英语空格分隔；这是呈现算法而非文案，不放入资源。
        return parts.joined(separator: language == .zhHans ? "" : " ")
    }

    private static func amountLabel(_ value: Int64, unitKey: String, language: AppLanguage,
                                    bundle: Bundle) -> String {
        let unit = LocalizedTextResolver.shared.string(forKey: unitKey, table: .localizable,
                                                       language: language, bundle: bundle)
        return LocalizedTextResolver.shared.string(forKey: "transfer.duration.amount.label",
                                                   table: .localizable, language: language,
                                                   arguments: [value, unit], bundle: bundle)
    }
}
