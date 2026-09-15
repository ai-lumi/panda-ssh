import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

// MARK: - LogEntry 与 LogLevel 测试

/// 验证 LogEntry 的 formatted 属性包含 ISO8601 时间戳、级别名、模块名和消息文本;
/// 验证 LogLevel 四个 case 各有对应的显示颜色。
final class LogEntryTests: XCTestCase {

    func testFormattedContainsAllParts() {
        let entry = LogEntry(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1723470000),
            level: .info,
            module: "SSH",
            message: "已连接"
        )
        let formatted = entry.formatted

        // 包含 ISO8601 时间戳(以 [ 开头)
        XCTAssertTrue(formatted.contains("["), "formatted 应以 [时间戳] 开头")
        // 包含级别名
        XCTAssertTrue(formatted.contains("INFO"), "formatted 应包含级别名 INFO")
        // 包含模块名
        XCTAssertTrue(formatted.contains("SSH"), "formatted 应包含模块名 SSH")
        // 包含消息文本
        XCTAssertTrue(formatted.contains("已连接"), "formatted 应包含消息文本")
    }

    func testFormattedContainsISO8601Timestamp() {
        let timestamp = Date(timeIntervalSince1970: 1723470000)
        let entry = LogEntry(id: 1, timestamp: timestamp, level: .debug, module: "App", message: "test")
        // ISO8601 格式应包含 T 和 Z
        XCTAssertTrue(entry.formatted.contains("T"), "时间戳应包含 T 分隔符")
        XCTAssertTrue(entry.formatted.contains("Z"), "时间戳应包含 Z 后缀(UTC)")
    }

    func testLogLevelDebugHasColor() {
        XCTAssertNotEqual(LogLevel.debug.color, Color.clear, "debug 级别应有非透明颜色")
    }

    func testLogLevelInfoHasColor() {
        XCTAssertNotEqual(LogLevel.info.color, Color.clear, "info 级别应有非透明颜色")
    }

    func testLogLevelWarningHasColor() {
        XCTAssertNotEqual(LogLevel.warning.color, Color.clear, "warning 级别应有非透明颜色")
    }

    func testLogLevelErrorHasColor() {
        XCTAssertNotEqual(LogLevel.error.color, Color.clear, "error 级别应有非透明颜色")
    }

    func testLogLevelDisplayName() {
        XCTAssertEqual(LogLevel.debug.displayName, "DEBUG")
        XCTAssertEqual(LogLevel.info.displayName, "INFO")
        XCTAssertEqual(LogLevel.warning.displayName, "WARNING")
        XCTAssertEqual(LogLevel.error.displayName, "ERROR")
    }
}

// MARK: - Logger 内存环形缓冲区测试

/// 覆盖正常流程、边界条件(缓冲区满)、意外操作(clear 后继续记录)。
final class LoggerBufferTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Rust 侧 logger 为全局单例，测试间共享缓冲区；每次测试前清空
        let logger = Logger(configDirectory: nil)
        logger.clear()
    }

    /// 临时目录,每次测试新建,隔离文件副作用。
    private func makeLogger(maxFileSize: Int64 = 1024) -> (Logger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logger-test-\(UUID().uuidString)")
        return (Logger(configDirectory: dir, maxFileSize: maxFileSize), dir)
    }

    func testBufferUnderLimit() {
        let (logger, _) = makeLogger()
        for i in 0..<500 {
            logger.info("消息 \(i)", module: "Test")
        }
        // @Published 更新在主线程异步派发,用 expectation 等待
        let exp = expectation(description: "entries 更新")
        DispatchQueue.main.async {
            XCTAssertEqual(logger.entries.count, 500, "500 条日志后缓冲区应为 500")
            XCTAssertEqual(logger.entries.first?.message, "消息 0")
            XCTAssertEqual(logger.entries.last?.message, "消息 499")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testBufferOverLimitDropsOldest() {
        let (logger, _) = makeLogger()
        for i in 0..<1001 {
            logger.info("消息 \(i)", module: "Test")
        }
        let exp = expectation(description: "entries 更新")
        DispatchQueue.main.async {
            XCTAssertEqual(logger.entries.count, 1000, "1001 条后缓冲区应为 1000")
            // 最旧条目(消息 0)被丢弃
            XCTAssertFalse(logger.entries.contains { $0.message == "消息 0" }, "最旧条目应被丢弃")
            XCTAssertEqual(logger.entries.first?.message, "消息 1")
            XCTAssertEqual(logger.entries.last?.message, "消息 1000")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testClearEmptiesBuffer() {
        let (logger, _) = makeLogger()
        logger.info("测试消息", module: "Test")
        logger.clear()

        let exp = expectation(description: "clear 后 entries 为空")
        DispatchQueue.main.async {
            XCTAssertTrue(logger.entries.isEmpty, "clear 后缓冲区应为空")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testCanLogAfterClear() {
        let (logger, _) = makeLogger()
        logger.info("旧消息", module: "Test")
        logger.clear()
        logger.info("新消息", module: "Test")

        let exp = expectation(description: "clear 后可继续记录")
        DispatchQueue.main.async {
            XCTAssertEqual(logger.entries.count, 1, "clear 后应只有 1 条")
            XCTAssertEqual(logger.entries.first?.message, "新消息")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testLogLevelStoredCorrectly() {
        let (logger, _) = makeLogger()
        logger.debug("d", module: "M")
        logger.info("i", module: "M")
        logger.warning("w", module: "M")
        logger.error("e", module: "M")

        let exp = expectation(description: "级别正确存储")
        DispatchQueue.main.async {
            XCTAssertEqual(logger.entries.count, 4)
            XCTAssertEqual(logger.entries[0].level, .debug)
            XCTAssertEqual(logger.entries[1].level, .info)
            XCTAssertEqual(logger.entries[2].level, .warning)
            XCTAssertEqual(logger.entries[3].level, .error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    /// 日志模块名白名单:默认模块名不得产生 spec 未定义的 `App`。
    func testDefaultModuleNameIsInWhitelist() {
        let (logger, _) = makeLogger()
        logger.log("默认模块名")

        let exp = expectation(description: "默认模块名在规范白名单内")
        DispatchQueue.main.async {
            guard let entry = logger.entries.first else {
                XCTFail("应有一条日志"); exp.fulfill(); return
            }
            XCTAssertTrue(
                ["SSH", "SFTP", "Transfer", "HostKey", "Config", "FFI"].contains(entry.module),
                "默认模块名 \(entry.module) 不在规范白名单中"
            )
            XCTAssertFalse(entry.formatted.contains("[App]"), "不应出现 App 模块名")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    /// 显式传入白名单外模块名的调用点应被修正(此处验证白名单辅助常量本身)。
    func testWhitelistedModuleNamesMatchSpec() {
        let modules = [LogModule.ssh, LogModule.sftp, LogModule.transfer,
                       LogModule.hostKey, LogModule.config, LogModule.ffi]
        XCTAssertEqual(modules, ["SSH", "SFTP", "Transfer", "HostKey", "Config", "FFI"])
    }
}

// MARK: - Logger 文件日志与轮转测试

/// 文件日志与轮转测试已迁移至 Rust 侧 (crates/panda-core/src/logger.rs)。
/// Swift 侧仅保留内存缓冲相关的测试，因为 Logger 的文件 I/O 完全委托给 Rust 全局 logger，
/// Swift 侧的 configDirectory 参数仅保留以兼容现有调用方，实际控制文件路径的是 Rust 侧的 init_store()。
/// 相关 Rust 测试：file_logging_writes_and_appends、file_rotation_creates_backup、concurrent_writes_do_not_crash。
final class LoggerFileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Rust 侧 logger 为全局单例，测试间共享缓冲区；每次测试前清空
        let logger = Logger(configDirectory: nil)
        logger.clear()
    }

    func testNilConfigDirectorySkipsFileLogging() {
        // 传 nil 不应崩溃,内存缓冲仍正常工作
        let logger = Logger(configDirectory: nil)
        logger.info("无文件模式", module: "Test")

        let exp = expectation(description: "无文件模式内存缓冲正常")
        DispatchQueue.main.async {
            XCTAssertEqual(logger.entries.count, 1)
            XCTAssertEqual(logger.entries.first?.message, "无文件模式")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testConcurrentWritesDoNotCrashOrLoseEntries() {
        let logger = Logger(configDirectory: nil)
        let count = 100
        let queue = DispatchQueue(label: "logger-concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for i in 0..<count {
            group.enter()
            queue.async {
                logger.info("msg-\(i)", module: "Test")
                group.leave()
            }
        }
        group.wait()

        // @Published entries 通过 DispatchQueue.main.async 更新,等待主线程处理
        let exp = expectation(description: "entries updated on main thread")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(logger.entries.count, count)
        let messages = Set(logger.entries.map(\.message))
        XCTAssertEqual(messages.count, count, "并发写入不应丢失条目")
    }
}
