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
        let entry = LogEntry(timestamp: timestamp, level: .debug, module: "App", message: "test")
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
            // 顺序正确
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
            // 最新条目(消息 1000)在末尾
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

/// 覆盖正常流程(写入/追加)、边界条件(轮转/覆盖)、意外操作(目录缺失/写入失败)。
final class LoggerFileTests: XCTestCase {

    private func makeLogger(dir: URL, maxFileSize: Int64 = 1024) -> Logger {
        Logger(configDirectory: dir, maxFileSize: maxFileSize)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("logger-file-\(UUID().uuidString)")
    }

    func testLogWritesToFile() {
        let dir = tempDir()
        let logger = makeLogger(dir: dir)
        logger.info("文件测试消息", module: "SSH")
        logger.flush()

        let logURL = dir.appendingPathComponent("logs/panda-ssh.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path), "日志文件应存在")

        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("文件测试消息"), "文件内容应包含日志消息")
        XCTAssertTrue(content.contains("SSH"), "文件内容应包含模块名")
    }

    func testAppendAfterReinit() {
        let dir = tempDir()

        let logger1 = makeLogger(dir: dir)
        logger1.info("第一次", module: "Test")
        logger1.flush()

        // 重新初始化(模拟重启)
        let logger2 = makeLogger(dir: dir)
        logger2.info("第二次", module: "Test")
        logger2.flush()

        let logURL = dir.appendingPathComponent("logs/panda-ssh.log")
        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("第一次"), "重启后应保留旧内容")
        XCTAssertTrue(content.contains("第二次"), "重启后应追加新内容")
    }

    func testRotationWhenFileSizeExceedsLimit() {
        let dir = tempDir()
        // 设小阈值(1 字节)以便触发轮转
        let logger = makeLogger(dir: dir, maxFileSize: 1)

        // 第一次写入:maxFileSize=1,格式化行约 60 字节,触发轮转
        // 空文件被轮转为 .1,新文件写入「第一条」
        logger.info("第一条", module: "Test")
        logger.flush()

        let logURL = dir.appendingPathComponent("logs/panda-ssh.log")
        let backupURL = logURL.appendingPathExtension("1")

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "应生成 .1 备份文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path), "应创建新日志文件")

        // 重新初始化(模拟重启),打开已有文件,再写入触发第二次轮转
        let logger2 = makeLogger(dir: dir, maxFileSize: 1)
        logger2.info("第二条", module: "Test")
        logger2.flush()

        // 第二次轮转:含「第一条」的文件被轮转为 .1(覆盖旧的空备份)
        let backupContent = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(backupContent.contains("第一条"), "备份文件应包含被轮转的旧日志")

        // 新文件应包含轮转后写入的「第二条」
        let newContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(newContent.contains("第二条"), "新文件应包含轮转后的新日志")
        XCTAssertFalse(newContent.contains("第一条"), "新文件不应包含旧日志")
    }

    func testRotationOverwritesOldBackup() {
        let dir = tempDir()
        // 第一次写入触发轮转:空文件→.1,新文件写入「第一批」
        let logger1 = makeLogger(dir: dir, maxFileSize: 1)
        logger1.info("第一批", module: "Test")
        logger1.flush()

        // 第二轮:重新初始化打开已有文件,再写入触发轮转
        // 含「第一批」的文件→.1(覆盖旧的空备份),新文件写入「第二批」
        let logger2 = makeLogger(dir: dir, maxFileSize: 1)
        logger2.info("第二批", module: "Test")
        logger2.flush()

        let backupURL = dir.appendingPathComponent("logs/panda-ssh.log.1")
        let backupContent = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
        // 第二次轮转后,备份应包含「第一批」(轮转前主文件的内容)
        XCTAssertTrue(backupContent.contains("第一批"), "第二次轮转后备份应包含第一批内容")
        XCTAssertFalse(backupContent.contains("第二批"), "备份不应包含第二批内容")

        let logURL = dir.appendingPathComponent("logs/panda-ssh.log")
        let newContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(newContent.contains("第二批"), "新文件应包含第二批内容")
    }

    func testDirectoryAutoCreated() {
        let dir = tempDir()
        // 目录不存在时 Logger 初始化应自动创建
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let logger = makeLogger(dir: dir)
        logger.info("目录测试", module: "Test")
        logger.flush()

        let logURL = dir.appendingPathComponent("logs/panda-ssh.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path), "目录不存在时应自动创建")
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
}
