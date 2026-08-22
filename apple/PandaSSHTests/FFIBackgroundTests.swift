import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// FFIBackground 后台调度测试：验证阻塞型 FFI 闭包在非主线程执行、
/// 结果正确回传、异常原样传播，且多个闭包可并行。
final class FFIBackgroundTests: XCTestCase {

    // MARK: - 正常流程：后台执行 + 结果回传

    func testRunsClosureOffMainThreadAndReturnsValue() async throws {
        let value = try await FFIBackground.run {
            Thread.isMainThread
        }
        XCTAssertFalse(value, "闭包应在非主线程执行")
    }

    func testReturnsClosureResult() async throws {
        let result = try await FFIBackground.run { 42 }
        XCTAssertEqual(result, 42)
    }

    func testStringResultRoundTrip() async throws {
        let result = try await FFIBackground.run { "/home/user" }
        XCTAssertEqual(result, "/home/user")
    }

    func testOptionalResult() async throws {
        let result: String? = try await FFIBackground.run { nil }
        XCTAssertNil(result)
    }

    // MARK: - 意外操作：异常传播

    func testErrorPropagatesFromClosure() async {
        enum TestError: Error, Equatable { case boom }
        do {
            _ = try await FFIBackground.run { () -> Int in throw TestError.boom }
            XCTFail("应抛出错误")
        } catch let error as TestError {
            XCTAssertEqual(error, .boom)
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    // MARK: - 边界条件：多闭包并行

    func testConcurrentClosuresRunInParallel() async throws {
        let start = Date()
        async let a = FFIBackground.run {
            Thread.sleep(forTimeInterval: 1.0)
            return "a"
        }
        async let b = FFIBackground.run {
            Thread.sleep(forTimeInterval: 1.0)
            return "b"
        }
        let (ra, rb) = try await (a, b)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(ra, "a")
        XCTAssertEqual(rb, "b")
        XCTAssertLessThan(elapsed, 1.9, "两个 1s 闭包并行执行应显著小于 2s（实测 \(elapsed)s）")
    }
}