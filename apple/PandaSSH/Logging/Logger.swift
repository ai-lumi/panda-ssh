import Foundation
import SwiftUI

// MARK: - 日志级别

/// 四级日志:debug → info → warning → error,UI 按级别着色。
enum LogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error

    var displayName: String { rawValue.uppercased() }

    var color: Color {
        switch self {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - 模块名常量

/// 各模块统一模块名,与 design.md 日志规范一致。
enum LogModule {
    static let ssh = "SSH"
    static let sftp = "SFTP"
    static let transfer = "Transfer"
    static let hostKey = "HostKey"
    static let config = "Config"
    static let ffi = "FFI"
}

// MARK: - 日志条目

/// 单条日志:时间戳 + 级别 + 模块名 + 消息。
/// `formatted` 属性生成 `[ISO8601] [LEVEL] [module] message` 格式文本。
struct LogEntry: Identifiable, Sendable, Equatable {
    let id: UInt64
    let timestamp: Date
    let level: LogLevel
    let module: String
    let message: String

    /// 格式化文本:`[2026-08-12T14:30:00Z] [INFO] [SSH] 已连接`
    var formatted: String {
        let ts = Self.formatter.string(from: timestamp)
        return "[\(ts)] [\(level.displayName)] [\(module)] \(message)"
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Logger

/// 运行时日志记录器:委托 Rust 侧环形缓冲区(1000 条)+ 文件日志(100MB 轮转)。
/// Swift 侧仅作为 FFI 转发壳,维护 `@Published entries` 供 SwiftUI 绑定。
/// 通过定时器从 Rust 侧拉取最新日志条目,保持 UI 同步。
final class Logger: ObservableObject {
    static let shared = Logger()

    /// 内存缓冲区上限(与 Rust 侧一致)。
    static let maxBufferEntries = 1000

    @Published private(set) var entries: [LogEntry] = []

    /// 定时拉取 Rust 侧日志条目的定时器。
    private var refreshTimer: Timer?

    /// 测试注入点(保留参数以兼容现有调用方);Rust 侧日志路径由 `init_store()` 决定。
    init(configDirectory: URL? = AppPaths.configDirectory, maxFileSize: Int64 = Logger.defaultMaxFileSize) {
        // Rust 侧 logger 在首次调用 logWrite 时懒初始化,无需 Swift 侧初始化文件 I/O。
        // 启动定时拉取,保持 @Published entries 与 Rust 侧同步。
        startRefreshTimer()
    }

    /// 默认文件大小轮转阈值(保留以兼容现有调用方;实际轮转由 Rust 处理)。
    static let defaultMaxFileSize: Int64 = 100 * 1024 * 1024

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - 日志记录

    /// 记录一条日志。写入 Rust 侧环形缓冲区与文件日志,然后刷新 @Published entries。
    /// `module` 必须使用规范模块名
    /// （SSH / SFTP / Transfer / HostKey / Config / FFI）；默认 `Config` 归入配置/通用类别。
    func log(_ message: String, level: LogLevel = .info, module: String = LogModule.config) {
        let ffiLevel: LogLevelEnum
        switch level {
        case .debug: ffiLevel = .debug
        case .info: ffiLevel = .info
        case .warning: ffiLevel = .warning
        case .error: ffiLevel = .error
        }
        logWrite(level: ffiLevel, module: module, message: message)
        // 写入后立即刷新,保证 UI 快速响应
        refreshEntries()
    }

    func debug(_ message: String, module: String = LogModule.config) { log(message, level: .debug, module: module) }
    func info(_ message: String, module: String = LogModule.config) { log(message, level: .info, module: module) }
    func warning(_ message: String, module: String = LogModule.config) { log(message, level: .warning, module: module) }
    func error(_ message: String, module: String = LogModule.config) { log(message, level: .error, module: module) }

    // MARK: - 清除

    /// 清空日志缓冲区(Rust 侧内存缓冲区与文件均不受影响;仅清空内存缓冲)。
    func clear() {
        logClear()
        refreshEntries()
    }

    // MARK: - 测试辅助

    /// 等待所有排队的文件 I/O 完成(仅测试用)。
    /// Rust 侧日志写入为同步操作,无需 flush;保留此方法以兼容现有测试。
    func flush() {
        // Rust 侧为同步写入,无需额外 flush
    }

    // MARK: - 内部

    /// 从 Rust 侧拉取最新日志条目并更新 @Published。
    private func refreshEntries() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshEntries()
            }
            return
        }
        let ffiEntries = logEntries(limit: UInt32(Self.maxBufferEntries))
        let mapped = ffiEntries.reversed().compactMap { ffiEntry -> LogEntry? in
            let level: LogLevel
            switch ffiEntry.level {
            case .debug: level = .debug
            case .info: level = .info
            case .warning: level = .warning
            case .error: level = .error
            }
            // 解析 ISO8601 时间戳
            let timestamp = ISO8601DateFormatter().date(from: ffiEntry.timestamp) ?? Date()
            return LogEntry(
                id: ffiEntry.id,
                timestamp: timestamp,
                level: level,
                module: ffiEntry.module,
                message: ffiEntry.message
            )
        }
        if entries != mapped {
            entries = mapped
        }
    }

    /// 启动定时拉取 Rust 侧日志条目(1Hz,仅用于捕获 Rust 侧直接写入的日志)。
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshEntries()
        }
    }
}
