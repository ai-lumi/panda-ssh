//! 日志系统：环形缓冲 + 文件轮转。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// 日志级别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Debug,
    Info,
    Warning,
    Error,
}

impl LogLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            LogLevel::Debug => "DEBUG",
            LogLevel::Info => "INFO",
            LogLevel::Warning => "WARNING",
            LogLevel::Error => "ERROR",
        }
    }
}

/// 日志条目。
#[derive(Debug, Clone)]
pub struct LogEntry {
    pub id: u64,
    pub timestamp: String,
    pub level: LogLevel,
    pub module: String,
    pub message: String,
}

/// 日志管理器：环形缓冲（内存）+ 文件轮转。
pub struct Logger {
    /// 环形缓冲，最多保留 `capacity` 条。
    buffer: Mutex<Vec<LogEntry>>,
    /// 缓冲容量上限。
    capacity: usize,
    next_id: AtomicU64,
    /// 避免文件系统持续失败时为每条业务日志重复插入同一条告警。
    persistence_error_reported: AtomicBool,
    /// 文件日志路径（None 表示不写文件）。
    file_path: Mutex<Option<PathBuf>>,
    /// 当前文件大小。
    file_size: Mutex<i64>,
    /// 文件轮转阈值（字节）。
    rotation_threshold: i64,
}

const DEFAULT_CAPACITY: usize = 1000;
const DEFAULT_ROTATION_THRESHOLD: i64 = 100 * 1024 * 1024; // 100MB

impl Logger {
    /// 创建日志管理器。
    pub fn new(file_path: Option<PathBuf>) -> Self {
        let file_size = file_path
            .as_ref()
            .and_then(|p| fs::metadata(p).ok())
            .map(|m| m.len() as i64)
            .unwrap_or(0);

        Self {
            buffer: Mutex::new(Vec::new()),
            capacity: DEFAULT_CAPACITY,
            next_id: AtomicU64::new(0),
            persistence_error_reported: AtomicBool::new(false),
            file_path: Mutex::new(file_path),
            file_size: Mutex::new(file_size),
            rotation_threshold: DEFAULT_ROTATION_THRESHOLD,
        }
    }

    /// 写入一条日志。
    pub fn log(&self, level: LogLevel, module: &str, message: &str) {
        let entry = LogEntry {
            id: self.next_id.fetch_add(1, Ordering::Relaxed) + 1,
            timestamp: now_iso8601(),
            level,
            module: module.to_string(),
            message: message.to_string(),
        };

        // 写入环形缓冲
        {
            let mut buffer = self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if buffer.len() >= self.capacity {
                buffer.remove(0);
            }
            buffer.push(entry.clone());
        }

        // 写入文件。先取出路径克隆再进入 if let：Rust 2021 中 if let 判别式
        // 的临时锁守卫会存活到块尾，若在块内 write 失败后再次加锁会自死锁。
        let path = self
            .file_path
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(path) = path {
            if self.write_to_file(&path, &entry).is_err() {
                self.disable_file_persistence();
            }
        }
    }

    /// 快捷方法。
    pub fn debug(&self, module: &str, message: &str) {
        self.log(LogLevel::Debug, module, message);
    }

    pub fn info(&self, module: &str, message: &str) {
        self.log(LogLevel::Info, module, message);
    }

    pub fn warning(&self, module: &str, message: &str) {
        self.log(LogLevel::Warning, module, message);
    }

    pub fn error(&self, module: &str, message: &str) {
        self.log(LogLevel::Error, module, message);
    }

    /// 获取最近的日志条目（按时间倒序）。
    pub fn entries(&self, limit: usize) -> Vec<LogEntry> {
        let buffer = self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        buffer.iter().rev().take(limit).cloned().collect()
    }

    /// 清空环形缓冲。
    pub fn clear(&self) {
        let mut buffer = self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        buffer.clear();
    }

    /// 当前缓冲条目数。
    pub fn len(&self) -> usize {
        self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).len()
    }

    /// 缓冲是否为空。
    pub fn is_empty(&self) -> bool {
        self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).is_empty()
    }

    /// 在配置目录就绪后启用文件持久化，并按原始顺序补写此前仅存在内存中的日志。
    pub fn configure_file_path(&self, path: PathBuf) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            if fs::create_dir_all(parent).is_err() {
                self.record_persistence_failure();
                return Ok(());
            }
        }
        *self
            .file_path
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(path.clone());
        let entries = self
            .buffer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        for entry in entries {
            if self.write_to_file(&path, &entry).is_err() {
                self.disable_file_persistence();
                return Ok(());
            }
        }
        Ok(())
    }

    /// 文件不可用时仍保留内存日志，并明确记录一次可见告警。
    fn disable_file_persistence(&self) {
        *self
            .file_path
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        self.record_persistence_failure();
    }

    fn record_persistence_failure(&self) {
        if self
            .persistence_error_reported
            .swap(true, Ordering::Relaxed)
        {
            return;
        }
        let entry = LogEntry {
            id: self.next_id.fetch_add(1, Ordering::Relaxed) + 1,
            timestamp: now_iso8601(),
            level: LogLevel::Error,
            module: "Config".into(),
            message: "日志文件不可写，当前仅保留内存日志".into(),
        };
        let mut buffer = self.buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if buffer.len() >= self.capacity {
            buffer.remove(0);
        }
        buffer.push(entry);
    }

    /// 写入文件并在达到阈值时轮转。
    fn write_to_file(&self, path: &Path, entry: &LogEntry) -> std::io::Result<()> {
        let line = format!(
            "[{}] [{}] [{}] {}\n",
            entry.timestamp,
            entry.level.as_str(),
            entry.module,
            entry.message
        );
        let bytes = line.as_bytes();

        // 检查是否需要轮转
        {
            let mut size = self.file_size.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if *size + bytes.len() as i64 > self.rotation_threshold {
                self.rotate_file(path)?;
                *size = 0;
            }
        }

        // 追加写入
        let mut file = OpenOptions::new().create(true).append(true).open(path)?;
        file.write_all(bytes)?;
        let mut size = self.file_size.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *size += bytes.len() as i64;
        Ok(())
    }

    /// 文件轮转：当前文件重命名为 .1，创建新文件。
    fn rotate_file(&self, path: &Path) -> std::io::Result<()> {
        let backup = path.with_extension("log.1");
        if path.exists() {
            fs::rename(path, &backup)?;
        }
        Ok(())
    }
}

static GLOBAL_LOGGER: OnceLock<Logger> = OnceLock::new();

/// SSH 与 FFI 共用的进程内日志服务。配置路径可在 `init_store` 后补齐。
pub fn global_logger() -> &'static Logger {
    GLOBAL_LOGGER.get_or_init(|| Logger::new(None))
}

pub fn configure_global_file_path(path: PathBuf) -> std::io::Result<()> {
    global_logger().configure_file_path(path)
}

/// 简单 ISO 8601 时间戳。
fn now_iso8601() -> String {
    use std::time::SystemTime;
    let dur = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;
    let (year, month, day) = days_to_ymd(days as i64);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn days_to_ymd(mut days: i64) -> (i64, u32, u32) {
    let mut year = 1970;
    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }
    let leap = is_leap_year(year);
    let month_days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut month = 1u32;
    for &md in &month_days {
        if days < md {
            break;
        }
        days -= md;
        month += 1;
    }
    (year, month, days as u32 + 1)
}

fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn log_write_adds_to_buffer() {
        let logger = Logger::new(None);
        assert!(logger.is_empty());
        logger.info("test", "hello");
        assert_eq!(logger.len(), 1);
        let entries = logger.entries(10);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "hello");
        assert_eq!(entries[0].level, LogLevel::Info);
        assert_eq!(entries[0].module, "test");
    }

    #[test]
    fn buffer_evicts_oldest_when_full() {
        let logger = Logger::new(None);
        for i in 0..1001 {
            logger.info("test", &format!("msg-{}", i));
        }
        // 容量 1000，第 1001 条写入后应淘汰第 0 条
        assert_eq!(logger.len(), 1000);
        let entries = logger.entries(1000);
        // 最新条目在最后（entries 是倒序的，所以 entries[0] 是最新的）
        assert_eq!(entries[0].message, "msg-1000");
        // 最旧条目应该是 msg-1（msg-0 被淘汰）
        assert_eq!(entries[999].message, "msg-1");
    }

    #[test]
    fn entries_returns_reverse_chronological() {
        let logger = Logger::new(None);
        logger.info("test", "first");
        logger.info("test", "second");
        logger.info("test", "third");
        let entries = logger.entries(10);
        assert_eq!(entries[0].message, "third");
        assert_eq!(entries[1].message, "second");
        assert_eq!(entries[2].message, "first");
    }

    #[test]
    fn entries_respects_limit() {
        let logger = Logger::new(None);
        for i in 0..10 {
            logger.info("test", &format!("msg-{}", i));
        }
        let entries = logger.entries(3);
        assert_eq!(entries.len(), 3);
    }

    #[test]
    fn clear_empties_buffer() {
        let logger = Logger::new(None);
        logger.info("test", "hello");
        logger.info("test", "world");
        assert_eq!(logger.len(), 2);
        logger.clear();
        assert!(logger.is_empty());
    }

    #[test]
    fn file_logging_writes_and_appends() {
        let dir = TempDir::new().unwrap();
        let log_path = dir.path().join("test.log");
        let logger = Logger::new(Some(log_path.clone()));

        logger.info("ssh", "connected");
        logger.error("sftp", "timeout");

        let content = fs::read_to_string(&log_path).unwrap();
        assert!(content.contains("[INFO] [ssh] connected"));
        assert!(content.contains("[ERROR] [sftp] timeout"));
    }

    #[test]
    fn logs_before_file_configuration_are_persisted_after_configuration() {
        let dir = TempDir::new().unwrap();
        let log_path = dir.path().join("logs/panda-ssh.log");
        let logger = Logger::new(None);
        logger.info("ssh", "连接成功");
        logger.configure_file_path(log_path.clone()).unwrap();

        let content = fs::read_to_string(log_path).unwrap();
        assert!(content.contains("连接成功"));
        assert!(logger.entries(1)[0].id > 0);
    }

    #[test]
    fn file_persistence_failure_is_retained_in_memory_log() {
        let dir = TempDir::new().unwrap();
        let occupied_parent = dir.path().join("not-a-directory");
        fs::write(&occupied_parent, "file").unwrap();
        let logger = Logger::new(None);

        logger.configure_file_path(occupied_parent.join("panda-ssh.log")).unwrap();

        assert!(logger.entries(10).iter().any(|entry| {
            entry.level == LogLevel::Error
                && entry.message == "日志文件不可写，当前仅保留内存日志"
        }));
    }

    /// 写入失败必须降级为仅内存日志，而不是在 `log` 内部对 file_path 互斥锁
    /// 二次加锁造成同线程死锁（Rust 2021 中 `if let` 判别式临时值存活到块尾）。
    #[test]
    fn log_write_failure_disables_file_persistence_without_deadlock() {
        let dir = TempDir::new().unwrap();
        let blocker = dir.path().join("not-a-directory");
        fs::write(&blocker, "file").unwrap();
        let logger = Logger::new(Some(blocker.join("panda-ssh.log")));

        logger.info("ssh", "第一次写入失败");
        logger.info("ssh", "失败后仅保留内存日志");

        assert!(logger.entries(10).iter().any(|entry| {
            entry.level == LogLevel::Error
                && entry.message == "日志文件不可写，当前仅保留内存日志"
        }));
        assert_eq!(logger.len(), 3);
    }

    #[test]
    fn file_rotation_creates_backup() {
        let dir = TempDir::new().unwrap();
        let log_path = dir.path().join("test.log");
        let mut logger = Logger::new(Some(log_path.clone()));
        logger.rotation_threshold = 100; // 很小的阈值方便测试

        // 写入足够多的数据触发轮转
        for i in 0..20 {
            logger.info("test", &format!("message number {} with some padding", i));
        }

        // 轮转后应该存在 .1 备份文件
        let backup = log_path.with_extension("log.1");
        assert!(backup.exists(), "backup file should exist after rotation");
    }

    #[test]
    fn concurrent_writes_do_not_crash() {
        use std::sync::Arc;
        use std::thread;

        let logger = Arc::new(Logger::new(None));
        let mut handles = vec![];

        for t in 0..10 {
            let logger = Arc::clone(&logger);
            handles.push(thread::spawn(move || {
                for i in 0..100 {
                    logger.info(&format!("thread-{}", t), &format!("msg-{}", i));
                }
            }));
        }

        for h in handles {
            h.join().unwrap();
        }

        // 10 线程 × 100 条 = 1000 条，刚好等于容量
        assert!(logger.len() <= 1000);
    }

    #[test]
    fn log_levels_are_correct() {
        assert_eq!(LogLevel::Debug.as_str(), "DEBUG");
        assert_eq!(LogLevel::Info.as_str(), "INFO");
        assert_eq!(LogLevel::Warning.as_str(), "WARNING");
        assert_eq!(LogLevel::Error.as_str(), "ERROR");
    }
}
