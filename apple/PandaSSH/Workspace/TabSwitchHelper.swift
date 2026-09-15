import Foundation

/// 计算下一个页签索引（从左往右循环切换）。
/// - Parameters:
///   - current: 当前页签索引
///   - total: 页签总数
/// - Returns: 下一个页签索引；空列表或无效索引时返回 nil
func nextTabIndex(current: Int, total: Int) -> Int? {
    guard total > 0, current >= 0, current < total else { return nil }
    return (current + 1) % total
}

/// 计算上一个页签索引（从右往左循环切换）。
/// - Parameters:
///   - current: 当前页签索引
///   - total: 页签总数
/// - Returns: 上一个页签索引；空列表或无效索引时返回 nil
func previousTabIndex(current: Int, total: Int) -> Int? {
    guard total > 0, current >= 0, current < total else { return nil }
    return (current - 1 + total) % total
}
