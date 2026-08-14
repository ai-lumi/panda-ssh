import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 传输速度计算单元测试：覆盖实时速度（滑动窗口）、总速度、
/// 剩余时间估算、边界条件（空窗口、单点、进度回退、时间异常）。
final class TransferSpeedCalculatorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 0)

    // MARK: - 实时速度

    func testLiveSpeedWithTwoPointsInWindow() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 0, at: start)
        calc.addSample(transferred: 1_000_000, at: start.addingTimeInterval(1))

        XCTAssertEqual(calc.liveSpeed, 1_000_000)
    }

    func testLiveSpeedUsesSlidingWindow() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 0, at: start)
        calc.addSample(transferred: 1_000_000, at: start.addingTimeInterval(1))
        calc.addSample(transferred: 3_000_000, at: start.addingTimeInterval(3))

        // 2 秒窗口：只保留 t=1 到 t=3 的数据点，速度 = 2MB / 2s = 1MB/s
        XCTAssertEqual(calc.liveSpeed, 1_000_000)
    }

    func testLiveSpeedIgnoresOutOfOrderBytes() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 1_000_000, at: start)
        calc.addSample(transferred: 500_000, at: start.addingTimeInterval(1))

        // 进度回退不崩溃、不返回负值：按实际差值计算会得负值，应夹紧到 0
        XCTAssertEqual(calc.liveSpeed, 0)
    }

    func testLiveSpeedWithSinglePointFallsBackToStart() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 1_000_000, at: start.addingTimeInterval(1))

        XCTAssertEqual(calc.liveSpeed, 1_000_000)
    }

    func testLiveSpeedWithNoSamplesIsZero() {
        let calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)

        XCTAssertEqual(calc.liveSpeed, 0)
    }

    func testLiveSpeedWithZeroIntervalIsZero() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 0, at: start)
        calc.addSample(transferred: 1_000_000, at: start)

        XCTAssertEqual(calc.liveSpeed, 0)
    }

    // MARK: - 总速度

    func testTotalSpeedAveragesOverTotalTime() {
        var calc = TransferSpeedCalculator(startTime: start, size: 30_000_000)
        calc.addSample(transferred: 15_000_000, at: start.addingTimeInterval(30))

        XCTAssertEqual(calc.totalSpeed, 500_000)
    }

    func testTotalSpeedIsZeroWhenNoBytesTransferred() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 0, at: start.addingTimeInterval(1))

        XCTAssertEqual(calc.totalSpeed, 0)
    }

    func testTotalSpeedIsZeroWhenStartTimeEqualsSampleTime() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 1_000_000, at: start)

        XCTAssertEqual(calc.totalSpeed, 0)
    }

    func testTotalSpeedClampsNegativeStartTime() {
        let futureStart = start.addingTimeInterval(10)
        var calc = TransferSpeedCalculator(startTime: futureStart, size: 10_000_000)
        calc.addSample(transferred: 1_000_000, at: start)

        // 起始时间晚于样本时间（时钟异常）时返回 0，不崩溃
        XCTAssertEqual(calc.totalSpeed, 0)
    }

    // MARK: - 剩余时间

    func testEstimatedTimeRemainingWhenSpeedPositive() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 0, at: start)
        calc.addSample(transferred: 5_000_000, at: start.addingTimeInterval(1))

        XCTAssertEqual(calc.estimatedTimeRemaining ?? 0, 1.0, accuracy: 0.01)
    }

    func testEstimatedTimeRemainingIsNilWhenNoSpeed() {
        var calc = TransferSpeedCalculator(startTime: start, size: 10_000_000)
        calc.addSample(transferred: 5_000_000, at: start)

        XCTAssertNil(calc.estimatedTimeRemaining)
    }

    func testEstimatedTimeRemainingIsNilWhenComplete() {
        var calc = TransferSpeedCalculator(startTime: start, size: 5_000_000)
        calc.addSample(transferred: 5_000_000, at: start.addingTimeInterval(1))

        XCTAssertNil(calc.estimatedTimeRemaining)
    }

    // MARK: - 格式化

    func testFormatBytesPerSecond() {
        XCTAssertEqual(formatSpeed(0), "0 B/s")
        XCTAssertEqual(formatSpeed(512), "512 B/s")
        XCTAssertEqual(formatSpeed(1023), "1023 B/s")
    }

    func testFormatKilobytesPerSecond() {
        XCTAssertEqual(formatSpeed(1024), "1.0 KB/s")
        XCTAssertEqual(formatSpeed(1536), "1.5 KB/s")
        XCTAssertEqual(formatSpeed(1024 * 1024 - 1), "1024.0 KB/s")
    }

    func testFormatMegabytesPerSecond() {
        XCTAssertEqual(formatSpeed(1024 * 1024), "1.0 MB/s")
        XCTAssertEqual(formatSpeed(5 * 1024 * 1024), "5.0 MB/s")
    }

    func testFormatGigabytesPerSecond() {
        XCTAssertEqual(formatSpeed(1024 * 1024 * 1024), "1.00 GB/s")
        XCTAssertEqual(formatSpeed(2 * 1024 * 1024 * 1024), "2.00 GB/s")
    }

    func testFormatSpeedClampsNegativeToZero() {
        XCTAssertEqual(formatSpeed(-1), "0 B/s")
    }

    // MARK: - 时间格式化

    func testFormatDuration() {
        XCTAssertEqual(formatDuration(0.5), "1 秒内")
        XCTAssertEqual(formatDuration(30), "30 秒")
        XCTAssertEqual(formatDuration(90), "1 分 30 秒")
        XCTAssertEqual(formatDuration(3600), "1 时 0 分")
    }
}
