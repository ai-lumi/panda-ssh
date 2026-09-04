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
struct LogEntry: Identifiable, Sendable {
    let id = UUID()
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

/// 运行时日志记录器:内存环形缓冲区(1000 条)+ 文件日志(100MB 轮转)。
/// 线程安全:内部 NSLock 保护缓冲区,私有串行队列处理文件 I/O,
/// @Published 更新派发到主线程。
final class Logger: ObservableObject {
    static let shared = Logger()

    /// 内存缓冲区上限。
    static let maxBufferEntries = 1000
    /// 文件大小轮转阈值(100 MB)。
    static let defaultMaxFileSize: Int64 = 100 * 1024 * 1024

    @Published private(set) var entries: [LogEntry] = []

    private let lock = NSLock()
    private var buffer: [LogEntry] = []

    private let ioQueue = DispatchQueue(label: "panda-ssh.logger.io")
    private var fileHandle: FileHandle?
    private var logFileURL: URL?
    private var currentFileSize: Int64 = 0
    private let maxFileSize: Int64

    /// 测试注入点:传入自定义目录路径与轮转阈值。传 nil 时不启用文件日志。
    init(configDirectory: URL? = AppPaths.configDirectory, maxFileSize: Int64 = Logger.defaultMaxFileSize) {
        self.maxFileSize = maxFileSize

        guard let configDir = configDirectory else { return }
        let logsDir = configDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("panda-ssh.log")
        openLogFile()
    }

    // MARK: - 日志记录

    /// 原因由 Rust 固定枚举生成；桥接层不读取终端数据或凭据。
    func logConnectionEvents(_ events: [ConnectionLifecycleRecord]) {
        for event in events {
            log("host=\(event.address); connection=\(event.connectionId); owner=\(event.ownerKind)#\(event.ownerId); \(event.reason)",
                level: event.isError ? .error : .info, module: LogModule.ssh)
        }
    }

    /// 记录一条日志。`module` 必须使用规范模块名
    /// （SSH / SFTP / Transfer / HostKey / Config / FFI）；默认 `Config` 归入配置/通用类别。
    func log(_ message: String, level: LogLevel = .info, module: String = LogModule.config) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            module: module,
            message: message
        )

        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.maxBufferEntries {
            buffer.removeFirst(buffer.count - Self.maxBufferEntries)
        }
        let snapshot = buffer
        lock.unlock()

        // 更新 @Published (主线程)
        DispatchQueue.main.async { [weak self] in
            self?.entries = snapshot
        }

        // 文件写入(异步,串行队列)
        let line = entry.formatted + "\n"
        guard let data = line.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            self?.performFileWrite(data)
        }
    }

    func debug(_ message: String, module: String = "App") { log(message, level: .debug, module: module) }
    func info(_ message: String, module: String = "App") { log(message, level: .info, module: module) }
    func warning(_ message: String, module: String = "App") { log(message, level: .warning, module: module) }
    func error(_ message: String, module: String = "App") { log(message, level: .error, module: module) }

    // MARK: - 清除

    /// 清空内存缓冲区(文件内容不受影响)。
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
    }

    // MARK: - 测试辅助

    /// 等待所有排队的文件 I/O 完成(仅测试用)。
    func flush() {
        ioQueue.sync { }
    }

    // MARK: - 文件 I/O

    private func openLogFile() {
        guard let url = logFileURL else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                currentFileSize = (attrs[.size] as? Int64) ?? 0
                fileHandle = try FileHandle(forWritingTo: url)
                fileHandle?.seekToEndOfFile()
            } catch {
                createLogFile()
            }
        } else {
            createLogFile()
        }
    }

    private func createLogFile() {
        guard let url = logFileURL else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: url)
            currentFileSize = 0
        } catch {
            fileHandle = nil
        }
    }

    private func performFileWrite(_ data: Data) {
        // 检查是否需要轮转
        if currentFileSize + Int64(data.count) > maxFileSize {
            rotateLogFile()
        }

        guard let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
            currentFileSize += Int64(data.count)
        } catch {
            // 写入失败 → 静默,内存缓冲不受影响
        }
    }

    private func rotateLogFile() {
        guard let url = logFileURL else { return }

        // 关闭当前文件
        try? fileHandle?.close()
        fileHandle = nil

        // 重命名为 .1(覆盖已有)
        let backupURL = url.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
        }
        try? FileManager.default.moveItem(at: url, to: backupURL)

        // 创建新文件
        createLogFile()
    }
}
