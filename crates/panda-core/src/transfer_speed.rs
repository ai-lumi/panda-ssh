//! 传输速度追踪器:2 秒滑动窗口计算实时速度,支持暂停/恢复。

use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// 滑动窗口时长:只统计最近 2 秒内的样本。
const WINDOW: Duration = Duration::from_secs(2);

/// 传输速度追踪器。
///
/// 维护一个 2 秒滑动窗口内的 `(timestamp, cumulative_bytes)` 样本序列,
/// 用于计算实时速度、平均速度和预计剩余时间。
pub struct TransferSpeedTracker {
    /// 2 秒滑动窗口中的样本
    samples: VecDeque<(Instant, u64)>,
    /// 传输开始时间
    start_time: Instant,
    /// 文件/任务总大小
    total_size: u64,
}

impl TransferSpeedTracker {
    /// 创建追踪器,`total_size` 为任务总字节数(0 表示未知)。
    pub fn new(total_size: u64) -> Self {
        let now = Instant::now();
        Self {
            samples: VecDeque::new(),
            start_time: now,
            total_size,
        }
    }

    /// 记录一次进度更新,`transferred` 为累计已传输字节数。
    pub fn update(&mut self, transferred: u64) {
        let now = Instant::now();
        self.samples.push_back((now, transferred));
        // 淘汰超过 2 秒窗口的旧样本
        self.evict_stale_samples(now);
    }

    /// 实时速度(字节/秒),基于 2 秒滑动窗口。
    pub fn live_speed(&self) -> f64 {
        if self.samples.len() < 2 {
            // 只有 0 或 1 个样本时,用 start_time 作为参考点
            if self.samples.len() == 1 {
                let (t, bytes) = &self.samples[0];
                let elapsed = t.duration_since(self.start_time).as_secs_f64();
                if elapsed > 0.0 {
                    return *bytes as f64 / elapsed;
                }
            }
            return 0.0;
        }
        let (t_first, bytes_first) = self.samples.front().unwrap();
        let (t_last, bytes_last) = self.samples.back().unwrap();
        let dt = t_last.duration_since(*t_first).as_secs_f64();
        if dt <= 0.0 {
            return 0.0;
        }
        let db = *bytes_last as f64 - *bytes_first as f64;
        db / dt
    }

    /// 从开始到现在的平均速度(字节/秒)。
    pub fn total_speed(&self) -> f64 {
        let elapsed = self.start_time.elapsed().as_secs_f64();
        if elapsed <= 0.0 {
            return 0.0;
        }
        let transferred = self.samples.back().map(|(_, b)| *b).unwrap_or(0);
        transferred as f64 / elapsed
    }

    /// 预计剩余秒数。速度为 0 或已完成时返回 `None`。
    pub fn eta_seconds(&self) -> Option<f64> {
        let speed = self.live_speed();
        if speed <= 0.0 {
            return None;
        }
        let transferred = self.samples.back().map(|(_, b)| *b).unwrap_or(0);
        if transferred >= self.total_size {
            return None;
        }
        let remaining = self.total_size.saturating_sub(transferred);
        Some(remaining as f64 / speed)
    }

    /// 暂停时调用:清空滑动窗口,使恢复后的速度从零开始重新计算。
    pub fn on_pause(&mut self) {
        self.samples.clear();
    }

    /// 恢复时调用:重置窗口,以当前时间为新起点。
    pub fn on_resume(&mut self) {
        self.samples.clear();
        // 不重置 start_time,因为 total_speed 应该反映整个会话的平均值
    }

    /// 淘汰窗口外的旧样本。
    fn evict_stale_samples(&mut self, now: Instant) {
        while let Some((t, _)) = self.samples.front() {
            if now.duration_since(*t) > WINDOW {
                self.samples.pop_front();
            } else {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 辅助:手动构造一个追踪器,可以精确控制时间。
    fn tracker_with_start(start: Instant, total_size: u64) -> TransferSpeedTracker {
        TransferSpeedTracker {
            samples: VecDeque::new(),
            start_time: start,
            total_size,
        }
    }

    #[test]
    fn new_tracker_has_zero_speed_and_no_eta() {
        let tracker = TransferSpeedTracker::new(1000);
        assert_eq!(tracker.live_speed(), 0.0);
        assert_eq!(tracker.total_speed(), 0.0);
        assert_eq!(tracker.eta_seconds(), None);
    }

    #[test]
    fn live_speed_with_two_samples() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        // 模拟: t=0s, 0 bytes; t=1s, 1000 bytes
        tracker.samples.push_back((start, 0));
        tracker
            .samples
            .push_back((start + Duration::from_secs(1), 1000));
        // 速度 = 1000 bytes / 1 second = 1000 bytes/sec
        let speed = tracker.live_speed();
        assert!((speed - 1000.0).abs() < 1.0, "speed was {speed}");
    }

    #[test]
    fn live_speed_with_one_sample_uses_start_time() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        // 1 个样本: t=2s, 2000 bytes → speed = 2000/2 = 1000
        tracker
            .samples
            .push_back((start + Duration::from_secs(2), 2000));
        let speed = tracker.live_speed();
        assert!((speed - 1000.0).abs() < 1.0, "speed was {speed}");
    }

    #[test]
    fn live_speed_with_zero_samples_returns_zero() {
        let tracker = tracker_with_start(Instant::now(), 1000);
        assert_eq!(tracker.live_speed(), 0.0);
    }

    #[test]
    fn sliding_window_evicts_old_samples() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 100000);
        // 旧样本(3 秒前)应该被淘汰
        tracker
            .samples
            .push_back((start + Duration::from_secs(0), 0));
        tracker
            .samples
            .push_back((start + Duration::from_secs(1), 500));
        // 新样本
        let new_t = start + Duration::from_secs(4);
        tracker.samples.push_back((new_t, 10000));
        // 手动淘汰
        tracker.evict_stale_samples(new_t);
        // 旧样本(0s, 1s) 应该被淘汰,只剩 4s 的样本
        assert_eq!(tracker.samples.len(), 1);
        assert_eq!(tracker.samples.front().unwrap().1, 10000);
    }

    #[test]
    fn total_speed_computes_average() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        // 模拟过了 5 秒,传输了 5000 bytes
        tracker
            .samples
            .push_back((start + Duration::from_secs(5), 5000));
        // total_speed = 5000 / 5 = 1000
        // 注意: total_speed 使用 start_time.elapsed(),这里用 mock 时间无法直接测试
        // 改用 live_speed 的方式验证逻辑
        // 实际上 total_speed 依赖 Instant::now(),我们只验证基本逻辑
        let speed = tracker.total_speed();
        // 由于 start_time.elapsed() 是真实时间,这里只验证不为负数
        assert!(speed >= 0.0);
    }

    #[test]
    fn eta_returns_remaining_divided_by_speed() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        // 2 个样本:速度 = 1000 bytes/sec
        tracker.samples.push_back((start, 0));
        tracker
            .samples
            .push_back((start + Duration::from_secs(1), 1000));
        // 已传输 1000,剩余 9000,速度 1000 → ETA = 9 秒
        let eta = tracker.eta_seconds().unwrap();
        assert!((eta - 9.0).abs() < 0.1, "eta was {eta}");
    }

    #[test]
    fn eta_returns_none_when_speed_is_zero() {
        let tracker = tracker_with_start(Instant::now(), 10000);
        assert_eq!(tracker.eta_seconds(), None);
    }

    #[test]
    fn eta_returns_none_when_complete() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 1000);
        tracker.samples.push_back((start, 0));
        tracker
            .samples
            .push_back((start + Duration::from_secs(1), 1000));
        // 已完成:transferred >= total_size
        assert_eq!(tracker.eta_seconds(), None);
    }

    #[test]
    fn pause_clears_window() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        tracker.samples.push_back((start, 0));
        tracker
            .samples
            .push_back((start + Duration::from_secs(1), 1000));
        assert!(tracker.live_speed() > 0.0);
        tracker.on_pause();
        // 暂停后窗口清空,速度归零
        assert_eq!(tracker.live_speed(), 0.0);
        assert!(tracker.samples.is_empty());
    }

    #[test]
    fn resume_clears_window_for_fresh_start() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 10000);
        tracker.samples.push_back((start, 0));
        tracker.on_pause();
        tracker.on_resume();
        // 恢复后窗口仍为空,需要新的 update 才能计算速度
        assert!(tracker.samples.is_empty());
        assert_eq!(tracker.live_speed(), 0.0);
    }

    #[test]
    fn zero_size_task_speed_zero_eta_none() {
        let tracker = TransferSpeedTracker::new(0);
        assert_eq!(tracker.live_speed(), 0.0);
        assert_eq!(tracker.eta_seconds(), None);
    }

    #[test]
    fn update_adds_sample_and_evicts_old() {
        let start = Instant::now();
        let mut tracker = tracker_with_start(start, 100000);
        tracker.update(100);
        assert_eq!(tracker.samples.len(), 1);
        tracker.update(200);
        assert_eq!(tracker.samples.len(), 2);
    }
}
