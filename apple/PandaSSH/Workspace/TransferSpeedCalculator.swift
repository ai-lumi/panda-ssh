import Foundation

/// 单个传输任务的速度计算器。基于采样点维护实时速度（滑动窗口）、
/// 总速度（全程平均）与剩余时间估算。
struct TransferSpeedCalculator {
    /// 任务开始时间，用于计算总速度。
    let startTime: Date
    /// 任务总大小（字节），用于估算剩余时间。
    let size: UInt64

    /// 进度采样点：(时间戳, 已传字节)。
    private var samples: [(date: Date, bytes: UInt64)] = []

    /// 实时速度窗口时长（秒）。
    static let liveWindow: TimeInterval = 2.0

    init(startTime: Date, size: UInt64) {
        self.startTime = startTime
        self.size = size
    }

    /// 添加一个进度采样点，并清理超出滑动窗口的旧数据。
    mutating func addSample(transferred bytes: UInt64, at date: Date) {
        samples.append((date, bytes))
        let cutoff = date.addingTimeInterval(-Self.liveWindow)
        samples.removeAll { $0.date < cutoff }
    }

    /// 重置窗口，用于任务从暂停恢复后继续上传/下载的场景。
    /// 保留当前已传输字节作为新的起始点，使实时速度从恢复时刻开始计算。
    mutating func reset(at date: Date, transferred bytes: UInt64) {
        samples = [(date, bytes)]
    }

    /// 实时速度（字节/秒）：窗口期内首尾采样点的平均速率。
    /// 窗口内只有一个采样点时，退化到与起始点计算。
    var liveSpeed: Int64 {
        guard let last = samples.last else { return 0 }
        guard let first = samples.first else { return 0 }
        let interval = last.date.timeIntervalSince(first.date)
        if interval > 0 {
            // 进度回退时夹紧到 0，避免负速度。
            let bytesDelta = Int64(last.bytes) - Int64(first.bytes)
            return max(0, Int64(Double(bytesDelta) / interval))
        }
        // 单个采样点：与任务开始时间计算速度。
        let startInterval = last.date.timeIntervalSince(startTime)
        guard startInterval > 0 else { return 0 }
        return Int64(Double(last.bytes) / startInterval)
    }

    /// 总速度（字节/秒）：从开始到最新采样点的平均速率。
    var totalSpeed: Int64 {
        guard let last = samples.last else { return 0 }
        let interval = last.date.timeIntervalSince(startTime)
        guard interval > 0 else { return 0 }
        return Int64(Double(last.bytes) / interval)
    }

    /// 预估剩余时间（秒）。速度为 0 或已完成时返回 nil。
    var estimatedTimeRemaining: TimeInterval? {
        guard let last = samples.last else { return nil }
        let remaining = last.bytes < size ? size - last.bytes : 0
        guard remaining > 0 else { return nil }
        let speed = liveSpeed
        guard speed > 0 else { return nil }
        return TimeInterval(remaining) / TimeInterval(speed)
    }
}

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
    if seconds < 1 { return "1 秒内" }
    if seconds < 60 { return "\(seconds) 秒" }
    let minutes = seconds / 60
    let secs = seconds % 60
    if minutes < 60 { return "\(minutes) 分 \(secs) 秒" }
    let hours = minutes / 60
    let mins = minutes % 60
    return "\(hours) 时 \(mins) 分"
}
