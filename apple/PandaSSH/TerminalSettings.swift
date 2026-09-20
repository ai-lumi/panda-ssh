import Foundation

/// 终端缓冲区行数的 UserDefaults 适配层。
///
/// 原始文本交给 Rust FFI 校验，Swift 只持久化 FFI 返回的规范化整数。
/// 不在 Swift 侧重复解析、夹限或决定默认值。
final class TerminalSettings {
    static let shared = TerminalSettings()

    private let defaults = UserDefaults.standard
    private let key = "terminal.bufferLines.raw"

    private init() {}

    /// 读取持久化的原始文本，交给 Rust 校验后返回规范化整数。
    /// 缺失或非法值回退默认值。
    func bufferLines() -> UInt32 {
        let raw = defaults.string(forKey: key) ?? ""
        return (try? validateTerminalBufferLines(raw: raw)) ?? defaultTerminalBufferLines()
    }

    /// 读取持久化的原始文本（供设置表单回显）。
    func rawBufferLines() -> String {
        let stored = defaults.string(forKey: key) ?? ""
        if stored.isEmpty {
            return String(defaultTerminalBufferLines())
        }
        return stored
    }

    /// 保存经 Rust 校验后的规范化整数（以字符串形式存储原始值）。
    func saveBufferLines(raw: String) throws {
        let validated = try validateTerminalBufferLines(raw: raw)
        defaults.set(String(validated), forKey: key)
    }
}
