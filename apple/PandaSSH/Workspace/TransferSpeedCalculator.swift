import Foundation

/// 速度格式化（字节/秒）：自动切换 B/s、KB/s、MB/s、GB/s，1024 进制。
/// 负值夹紧到 0，避免异常输入产生无意义文案。
func formatSpeed(_ bytesPerSecond: Int64) -> String {
    let bps = max(0, bytesPerSecond)
    let value = Double(bps)
    if bps < 1024 { return "\(bps) B/s" }
    if value < 1024 * 1024 { return String(format: "%.1f KB/s", value / 1024) }
    if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", value / 1024 / 1024) }
    return String(format: "%.2f GB/s", value / 1024 / 1024 / 1024)
}

/// 剩余时间格式化：小于 1 秒显示"1 秒内"，其余按秒/分/时展示。
func formatDuration(_ interval: TimeInterval) -> String {
    let seconds = Int(interval)
    if seconds < 1 { return l10n.str("transfer.duration.zero.message") }
    if seconds < 60 {
        return "\(seconds) \(l10n.str("transfer.duration.second.unit"))"
    }
    let minutes = seconds / 60
    let secs = seconds % 60
    if minutes < 60 {
        return "\(minutes) \(l10n.str("transfer.duration.minute.unit")) \(secs) \(l10n.str("transfer.duration.second.unit"))"
    }
    let hours = minutes / 60
    let mins = minutes % 60
    return "\(hours) \(l10n.str("transfer.duration.hour.unit")) \(mins) \(l10n.str("transfer.duration.minute.unit"))"
}
