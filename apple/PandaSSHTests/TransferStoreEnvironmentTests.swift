import SwiftUI
import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// `\.transferStore` 环境键语义：存纯引用、不建立订阅。
/// 订阅行为（读取环境值不触发视图失效）依赖 SwiftUI 渲染管线私有行为，
/// 无法用 XCTest 断言，以编译期类型约束兜底（EnvironmentValues 只存引用，
/// 与 environmentObject 的订阅语义在类型上区分）。
@MainActor
final class TransferStoreEnvironmentTests: XCTestCase {
    // MARK: 正常流程

    func test注入后读取返回同一实例引用() {
        let store = TransferStore(failRule: nil)
        var env = EnvironmentValues()
        env.transferStore = store
        XCTAssertTrue(env.transferStore === store)
    }

    // MARK: 意外操作

    func test未注入时读取默认空实现不崩溃() {
        let env = EnvironmentValues()
        XCTAssertTrue(env.transferStore.tasks.isEmpty)
    }

    // MARK: 边界条件

    func test多次注入同一实例返回一致引用() {
        let store = TransferStore(failRule: nil)
        var first = EnvironmentValues()
        first.transferStore = store
        var second = EnvironmentValues()
        second.transferStore = store
        XCTAssertTrue(first.transferStore === store)
        XCTAssertTrue(second.transferStore === store)
    }

    func test覆盖注入后读取返回最后注入的实例() {
        let old = TransferStore(failRule: nil)
        let new = TransferStore(failRule: nil)
        var env = EnvironmentValues()
        env.transferStore = old
        env.transferStore = new
        XCTAssertTrue(env.transferStore === new)
        XCTAssertFalse(env.transferStore === old)
    }
}
