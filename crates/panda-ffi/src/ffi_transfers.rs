//! 传输域 FFI 导出：单文件/批量任务、聚合、注册表、调度和状态转换。

#[path = "batch_transfer.rs"]
mod batch_transfer;
pub use batch_transfer::{
    batch_transfer_cancel, batch_transfer_list, batch_transfer_resolve_conflict,
    batch_transfer_status, scan_local_batch, scan_remote_batch, start_batch_download,
    start_batch_upload, BatchConflictRecord, BatchItemRecord, BatchTransferDirectionEnum,
    BatchTransferStatusEnum, BatchTransferStatusRecord,
};

#[path = "task_aggregation.rs"]
mod task_aggregation;
pub use task_aggregation::{
    aggregate_task_groups_ffi, AggregationResultRecord, TaskGroupRecord, TaskItemRecord,
};

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use panda_core::{KnownHosts, SftpClient, SshSession, TransferSpeedTracker, UnknownHostKeyPolicy};
use uuid::Uuid;

use crate::ffi_runtime::runtime;
use crate::ffi_store::{credentials_for, load_host, stores};
use crate::PandaError;

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

const TRANSFER_CONCURRENCY: usize = 3;

/// Direction of a transfer task.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum TransferDirectionEnum {
    Upload,
    Download,
}

/// Lifecycle state of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TransferStatusEnum {
    Queued,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

/// FFI-friendly snapshot of a transfer task.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferStatusRecord {
    pub id: String,
    pub direction: TransferDirectionEnum,
    pub host_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub transferred: u64,
    pub status: TransferStatusEnum,
    pub error: Option<String>,
    /// 单调递增版本号；任何状态/进度/错误变更时自动递增。
    pub version: u64,
    /// 实时传输速率（字节/秒），基于 2 秒滑动窗口。
    pub speed: f64,
    /// 从开始到现在的平均速率（字节/秒）。
    pub total_speed: f64,
    /// 预估剩余秒数；无法计算时为 None。
    pub eta_seconds: Option<f64>,
    /// 所属任务组 id；None 表示不属于任何组。
    pub group_id: Option<String>,
    /// 所属任务组名称。
    pub group_name: Option<String>,
}

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

/// Internal task record, shared between the registry and the async worker.
#[derive(Clone)]
struct TransferTask {
    id: Uuid,
    direction: TransferDirectionEnum,
    host_id: String,
    local_path: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    size: u64,
    status: Arc<std::sync::Mutex<TransferStatusEnum>>,
    transferred: Arc<AtomicU64>,
    error: Arc<std::sync::Mutex<Option<String>>>,
    cancel: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    resume_notify: Arc<tokio::sync::Notify>,
    version: Arc<AtomicU64>,
    speed_tracker: Arc<Mutex<TransferSpeedTracker>>,
    group_id: Option<String>,
    group_name: Option<String>,
}

impl TransferTask {
    fn snapshot(&self) -> TransferStatusRecord {
        let tracker = self.speed_tracker.lock().unwrap();
        TransferStatusRecord {
            id: self.id.to_string(),
            direction: self.direction.clone(),
            host_id: self.host_id.clone(),
            local_path: self.local_path.clone(),
            remote_path: self.remote_path.clone(),
            size: self.size,
            transferred: self.transferred.load(Ordering::Relaxed),
            status: *self.status.lock().unwrap(),
            error: self.error.lock().unwrap().clone(),
            version: self.version.load(Ordering::Relaxed),
            speed: tracker.live_speed(),
            total_speed: tracker.total_speed(),
            eta_seconds: tracker.eta_seconds(),
            group_id: self.group_id.clone(),
            group_name: self.group_name.clone(),
        }
    }

    /// 上传与下载共用进度通知，保证仅字节变化时也刷新 UI。
    fn progress_callback(&self) -> Arc<dyn Fn(u64, u64) + Send + Sync> {
        let task = self.clone();
        Arc::new(move |done, _total| {
            task.transferred.store(done, Ordering::Relaxed);
            task.speed_tracker.lock().unwrap().update(done);
            task.bump_version();
            notify_transfer_changed();
        })
    }

    /// 递增版本号，在状态/进度/错误变更后调用。
    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }
}

static TRANSFER_TASKS: OnceLock<Mutex<HashMap<Uuid, TransferTask>>> = OnceLock::new();
static TRANSFER_SEMAPHORE: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
/// 全局传输变更计数器；每次任务状态转换时递增。
/// Swift 侧可低频轮询此值，仅在变化时调用 `transfer_list()` 获取完整快照。
static TRANSFER_CHANGE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn transfer_tasks() -> &'static Mutex<HashMap<Uuid, TransferTask>> {
    TRANSFER_TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn transfer_semaphore() -> &'static tokio::sync::Semaphore {
    TRANSFER_SEMAPHORE.get_or_init(|| tokio::sync::Semaphore::new(TRANSFER_CONCURRENCY))
}

/// 状态变更时调用：递增全局变更计数器。
fn notify_transfer_changed() {
    TRANSFER_CHANGE_COUNTER.fetch_add(1, Ordering::Relaxed);
}

fn total_size(local: &std::path::Path) -> u64 {
    std::fs::metadata(local).map(|m| m.len()).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Task lifecycle
// ---------------------------------------------------------------------------

/// Start an upload or download task and return its id immediately.
/// The task runs on the global tokio runtime; use `transfer_status` / `transfer_list`
/// to poll progress.
#[uniffi::export]
pub fn start_transfer(
    direction: TransferDirectionEnum,
    host_id: String,
    local_path: String,
    remote_path: String,
    size: u64,
    password: Option<String>,
    passphrase: Option<String>,
    group_id: Option<String>,
    group_name: Option<String>,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    // 上传时若 Swift 未提供大小(传 0),则从本地文件系统计算;
    // 下载时使用 Swift 从 SFTP 列表中已获取的远端大小。
    let size = match direction {
        TransferDirectionEnum::Upload if size == 0 => {
            total_size(PathBuf::from(&local_path).as_path())
        }
        _ => size,
    };
    let id = Uuid::new_v4();
    let task = TransferTask {
        id,
        direction,
        host_id,
        local_path,
        remote_path,
        password,
        passphrase,
        size,
        status: Arc::new(std::sync::Mutex::new(TransferStatusEnum::Queued)),
        transferred: Arc::new(AtomicU64::new(0)),
        error: Arc::new(std::sync::Mutex::new(None)),
        cancel: Arc::new(AtomicBool::new(false)),
        paused: Arc::new(AtomicBool::new(false)),
        resume_notify: Arc::new(tokio::sync::Notify::new()),
        version: Arc::new(AtomicU64::new(1)),
        speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(size))),
        group_id,
        group_name,
    };
    transfer_tasks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, task.clone());
    notify_transfer_changed();

    runtime().spawn(async move {
        run_transfer_task(task, cfg).await;
    });
    Ok(id.to_string())
}

/// 当任务被暂停时阻塞，直到继续或被取消。
async fn wait_while_paused(task: &TransferTask) {
    loop {
        if task.cancel.load(Ordering::Relaxed) {
            return;
        }
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        {
            let mut status = task.status.lock().unwrap();
            if *status == TransferStatusEnum::Cancelled {
                return;
            }
            *status = TransferStatusEnum::Paused;
            drop(status);
            notify_transfer_changed();
        }
        // 先注册等待再检查,避免 resume 通知在 await 前丢失。
        let notified = task.resume_notify.notified();
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        notified.await;
    }
}

async fn run_transfer_task(task: TransferTask, cfg: panda_core::HostConfig) {
    // 排队阶段若被暂停，则等待恢复后再竞争信号量。
    wait_while_paused(&task).await;
    if task.cancel.load(Ordering::Relaxed) {
        *task.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        notify_transfer_changed();
        return;
    }

    // 先获取信号量许可证,获取成功前保持 Queued 状态,让 UI 正确显示排队中。
    let _permit = match transfer_semaphore().acquire().await {
        Ok(p) => p,
        Err(_) => {
            *task.status.lock().unwrap() = TransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some("semaphore closed".to_string());
            notify_transfer_changed();
            return;
        }
    };

    // 获取信号量后再次被暂停，则先进入 Paused，等恢复后再 Running。
    wait_while_paused(&task).await;

    {
        let mut status = task.status.lock().unwrap();
        if *status == TransferStatusEnum::Cancelled {
            return;
        }
        *status = TransferStatusEnum::Running;
    }
    task.bump_version();
    notify_transfer_changed();

    let result = match task.direction {
        TransferDirectionEnum::Upload => run_upload(&task, &cfg).await,
        TransferDirectionEnum::Download => run_download(&task, &cfg).await,
    };

    match result {
        Ok(()) => {
            *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Completed;
            if matches!(task.direction, TransferDirectionEnum::Upload) {
                task.transferred.store(task.size, Ordering::Relaxed);
            }
            task.bump_version();
            notify_transfer_changed();
        }
        Err(e) => {
            if task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) =
                    TransferStatusEnum::Cancelled;
            } else {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Failed;
                *task.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(e.to_string());
            }
            task.bump_version();
            notify_transfer_changed();
        }
    }
}

async fn run_upload(
    task: &TransferTask,
    cfg: &panda_core::HostConfig,
) -> Result<(), panda_core::Error> {
    let creds = credentials_for(cfg, task.password.clone(), task.passphrase.clone())
        .map_err(|e| panda_core::Error::Other(e.to_string()))?;
    let store_path = match stores() {
        Ok(s) => s.known_hosts.path().to_path_buf(),
        Err(e) => return Err(panda_core::Error::Other(e.to_string())),
    };
    let mut known_hosts = KnownHosts::new(store_path);
    let session = SshSession::connect_shared(
        cfg,
        creds,
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await?;
    session.set_owner("上传任务", task.id.to_string());
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let progress = task.progress_callback();
    let result = sftp
        .upload_with_pause(
            local.as_path(),
            &task.remote_path,
            Some(progress),
            Some(task.cancel.clone()),
            Some(task.paused.clone()),
            Some(task.resume_notify.clone()),
        )
        .await;
    let _ = sftp.close().await;
    result
}

async fn run_download(
    task: &TransferTask,
    cfg: &panda_core::HostConfig,
) -> Result<(), panda_core::Error> {
    let creds = credentials_for(cfg, task.password.clone(), task.passphrase.clone())
        .map_err(|e| panda_core::Error::Other(e.to_string()))?;
    let store_path = match stores() {
        Ok(s) => s.known_hosts.path().to_path_buf(),
        Err(e) => return Err(panda_core::Error::Other(e.to_string())),
    };
    let mut known_hosts = KnownHosts::new(store_path);
    let session = SshSession::connect_shared(
        cfg,
        creds,
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await?;
    session.set_owner("下载任务", task.id.to_string());
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let progress = task.progress_callback();
    let result = sftp
        .download_with_pause(
            &task.remote_path,
            local.as_path(),
            Some(progress),
            Some(task.cancel.clone()),
            Some(task.paused.clone()),
            Some(task.resume_notify.clone()),
        )
        .await;
    let _ = sftp.close().await;
    result
}

// ---------------------------------------------------------------------------
// Status query and control exports
// ---------------------------------------------------------------------------

/// Get a single task's current status.
#[uniffi::export]
pub fn transfer_status(task_id: String) -> Result<TransferStatusRecord, PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    Ok(task.snapshot())
}

/// List all tasks ordered by creation time (ids are UUID v4, which are roughly
/// time-ordered; we sort by id string for deterministic output).
#[uniffi::export]
pub fn transfer_list() -> Result<Vec<TransferStatusRecord>, PandaError> {
    let tasks = transfer_tasks().lock().unwrap();
    let mut records: Vec<_> = tasks.values().map(|t| t.snapshot()).collect();
    records.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(records)
}

/// 聚合状态优先级：running > paused > queued > failed > cancelled > completed。
fn group_status_priority(statuses: &[TransferStatusEnum]) -> TransferStatusEnum {
    let set: std::collections::HashSet<_> = statuses.iter().copied().collect();
    if set.contains(&TransferStatusEnum::Running) {
        TransferStatusEnum::Running
    } else if set.contains(&TransferStatusEnum::Paused) {
        TransferStatusEnum::Paused
    } else if set.contains(&TransferStatusEnum::Queued) {
        TransferStatusEnum::Queued
    } else if set.contains(&TransferStatusEnum::Failed) {
        TransferStatusEnum::Failed
    } else if set.contains(&TransferStatusEnum::Cancelled) {
        TransferStatusEnum::Cancelled
    } else {
        TransferStatusEnum::Completed
    }
}

/// 任务组聚合记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferGroupRecord {
    pub group_id: String,
    pub group_name: String,
    pub direction: TransferDirectionEnum,
    pub total_count: u32,
    pub completed_count: u32,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub status: TransferStatusEnum,
}

/// 返回按 group_id 聚合的任务组列表。无分组任务不出现在结果中。
#[uniffi::export]
pub fn transfer_groups() -> Result<Vec<TransferGroupRecord>, PandaError> {
    let tasks = transfer_tasks().lock().unwrap();
    let mut groups: std::collections::HashMap<
        String,
        (
            String,
            TransferDirectionEnum,
            Vec<TransferStatusEnum>,
            u64,
            u64,
            u32,
        ),
    > = std::collections::HashMap::new();

    for task in tasks.values() {
        if let (Some(gid), Some(gname)) = (&task.group_id, &task.group_name) {
            let entry = groups
                .entry(gid.clone())
                .or_insert_with(|| (gname.clone(), task.direction, Vec::new(), 0, 0, 0));
            let status = *task.status.lock().unwrap();
            entry.2.push(status);
            entry.3 += task.size;
            entry.4 += task.transferred.load(Ordering::Relaxed);
            entry.5 += 1;
        }
    }

    let mut result: Vec<TransferGroupRecord> = groups
        .into_iter()
        .map(
            |(gid, (gname, dir, statuses, total_bytes, transferred_bytes, total_count))| {
                let completed_count = statuses
                    .iter()
                    .filter(|s| {
                        matches!(
                            s,
                            TransferStatusEnum::Completed
                                | TransferStatusEnum::Failed
                                | TransferStatusEnum::Cancelled
                        )
                    })
                    .count() as u32;
                TransferGroupRecord {
                    group_id: gid,
                    group_name: gname,
                    direction: dir,
                    total_count,
                    completed_count,
                    total_bytes,
                    transferred_bytes,
                    status: group_status_priority(&statuses),
                }
            },
        )
        .collect();
    result.sort_by(|a, b| a.group_name.cmp(&b.group_name));
    Ok(result)
}

/// Cancel a queued, paused or running task. Idempotent for already-terminal tasks.
#[uniffi::export]
pub fn transfer_cancel(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.cancel.store(true, Ordering::Relaxed);
    task.resume_notify.notify_waiters();
    let status = *task.status.lock().unwrap();
    if matches!(
        status,
        TransferStatusEnum::Queued | TransferStatusEnum::Paused
    ) {
        *task.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        task.bump_version();
        notify_transfer_changed();
    }
    Ok(())
}

/// Retry a failed or cancelled task, reusing the same task id.
/// 重置任务状态为 Queued 后重新调度,避免在队列中产生新任务条目。
#[uniffi::export]
pub fn transfer_retry(task_id: String) -> Result<String, PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let task = {
        let tasks = transfer_tasks().lock().unwrap();
        tasks
            .get(&id)
            .ok_or_else(|| PandaError::UnknownTransferTask(task_id.clone()))?
            .clone()
    };

    {
        let status = *task.status.lock().unwrap();
        if !matches!(
            status,
            TransferStatusEnum::Failed | TransferStatusEnum::Cancelled
        ) {
            return Err(PandaError::Core(
                "task is not in a retryable state".to_string(),
            ));
        }
    }

    let cfg = load_host(&task.host_id)?;

    // 重置共享状态,保留原 id、路径与大小。
    *task.status.lock().unwrap() = TransferStatusEnum::Queued;
    task.transferred.store(0, Ordering::Relaxed);
    *task.error.lock().unwrap() = None;
    task.cancel.store(false, Ordering::Relaxed);
    task.paused.store(false, Ordering::Relaxed);
    *task.speed_tracker.lock().unwrap() = TransferSpeedTracker::new(task.size);
    task.resume_notify.notify_waiters();
    task.bump_version();
    notify_transfer_changed();

    runtime().spawn(async move {
        run_transfer_task(task, cfg).await;
    });
    Ok(id.to_string())
}

/// Pause a queued or running task.
/// 非终态任务可被暂停；已终态或已暂停任务为 no-op。
#[uniffi::export]
pub fn transfer_pause(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    let status = *task.status.lock().unwrap();
    if matches!(
        status,
        TransferStatusEnum::Completed | TransferStatusEnum::Failed | TransferStatusEnum::Cancelled
    ) {
        return Err(PandaError::Core("task is already terminal".to_string()));
    }
    task.paused.store(true, Ordering::Relaxed);
    task.speed_tracker.lock().unwrap().on_pause();
    if matches!(
        status,
        TransferStatusEnum::Queued | TransferStatusEnum::Running
    ) {
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        task.bump_version();
        notify_transfer_changed();
    }
    Ok(())
}

/// Resume a paused task.
/// 继续后会由工作线程重新竞争信号量或恢复 Running；非暂停任务为 no-op。
#[uniffi::export]
pub fn transfer_resume(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.paused.store(false, Ordering::Relaxed);
    task.speed_tracker.lock().unwrap().on_resume();
    let status = *task.status.lock().unwrap();
    if status == TransferStatusEnum::Paused {
        *task.status.lock().unwrap() = TransferStatusEnum::Queued;
        task.bump_version();
        notify_transfer_changed();
    }
    task.resume_notify.notify_waiters();
    Ok(())
}

/// 返回全局传输变更计数器。
/// Swift 侧低频轮询此值（如每 100ms），仅在返回值变化时调用 `transfer_list()` 获取完整快照，
/// 替代原先基于 Combine Timer 的无差别轮询。
#[uniffi::export]
pub fn transfer_change_counter() -> u64 {
    TRANSFER_CHANGE_COUNTER.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::global_test_lock;

    /// 构造一个假的 TransferTask 用于测试（不启动异步工作线程）。
    fn make_test_task(id: Uuid) -> TransferTask {
        TransferTask {
            id,
            direction: TransferDirectionEnum::Upload,
            host_id: "test-host".into(),
            local_path: "/tmp/test".into(),
            remote_path: "/remote/test".into(),
            password: None,
            passphrase: None,
            size: 1024,
            status: Arc::new(std::sync::Mutex::new(TransferStatusEnum::Queued)),
            transferred: Arc::new(AtomicU64::new(0)),
            error: Arc::new(std::sync::Mutex::new(None)),
            cancel: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            version: Arc::new(AtomicU64::new(1)),
            speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(1024))),
            group_id: None,
            group_name: None,
        }
    }

    /// 将测试任务插入全局注册表。
    fn insert_test_task(task: &TransferTask) {
        transfer_tasks()
            .lock()
            .unwrap()
            .insert(task.id, task.clone());
    }

    /// 从全局注册表移除测试任务。
    fn remove_test_task(id: &Uuid) {
        transfer_tasks().lock().unwrap().remove(id);
    }

    #[test]
    fn progress_alone_advances_revision_and_snapshot() {
        let _test_guard = global_test_lock();
        let task = make_test_task(Uuid::new_v4());
        let progress = task.progress_callback();
        for done in [1, 512, 1024] {
            let before = transfer_change_counter();
            progress(done, 1024);
            assert!(
                transfer_change_counter() > before,
                "仅字节进度也必须通知订阅方"
            );
            assert_eq!(task.snapshot().transferred, done);
        }
    }

    #[test]
    fn change_counter_increments_on_notify() {
        let _test_guard = global_test_lock();
        let before = transfer_change_counter();
        notify_transfer_changed();
        let after = transfer_change_counter();
        assert_eq!(after, before + 1);
    }

    #[test]
    fn change_counter_does_not_increment_on_read() {
        let _test_guard = global_test_lock();
        // 读取计数器本身不改变它的值
        let v1 = transfer_change_counter();
        let v2 = transfer_change_counter();
        assert_eq!(v1, v2);
    }

    #[test]
    fn change_counter_increments_on_cancel() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_cancel(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "cancel should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_pause() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_pause(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "pause should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_resume() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        // 先暂停
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_resume(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "resume should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_multiple_transitions_accumulate() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let c0 = transfer_change_counter();

        // Queued → Paused
        let _ = transfer_pause(id.to_string());
        let c1 = transfer_change_counter();
        assert!(c1 >= c0 + 1, "pause should bump counter by at least 1");

        // Paused → Queued (resume)
        let _ = transfer_resume(id.to_string());
        let c2 = transfer_change_counter();
        assert!(c2 >= c1 + 1, "resume should bump counter by at least 1");

        // Queued → Cancelled
        let _ = transfer_cancel(id.to_string());
        let c3 = transfer_change_counter();
        assert!(c3 >= c2 + 1, "cancel should bump counter by at least 1");

        // 总共至少递增了 3 次
        assert!(
            c3 >= c0 + 3,
            "three transitions should bump counter by at least 3"
        );

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_cancel() {
        let _test_guard = global_test_lock();
        // 已完成的任务 cancel 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Completed;
        insert_test_task(&task);

        let _ = transfer_cancel(id.to_string());
        // 状态应保持 Completed，不应被改为 Cancelled
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Completed,
            "cancelling a completed task should not change its status"
        );

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_pause() {
        let _test_guard = global_test_lock();
        // 已暂停的任务再次 pause 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let _ = transfer_pause(id.to_string());
        // 状态应保持 Paused（不会重复触发 notify）
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Paused,
            "pausing an already paused task should not change its status"
        );

        remove_test_task(&id);
    }

    // -----------------------------------------------------------------------
    // 状态聚合与任务组
    // -----------------------------------------------------------------------

    #[test]
    fn group_status_priority_prefers_running_over_all_terminal_states() {
        let _test_guard = global_test_lock();
        use TransferStatusEnum as S;
        assert_eq!(
            group_status_priority(&[S::Failed, S::Running, S::Completed]),
            S::Running
        );
        assert_eq!(group_status_priority(&[S::Completed, S::Paused]), S::Paused);
        assert_eq!(group_status_priority(&[S::Completed, S::Queued]), S::Queued);
        assert_eq!(group_status_priority(&[S::Cancelled, S::Failed]), S::Failed);
        assert_eq!(group_status_priority(&[S::Cancelled]), S::Cancelled);
        assert_eq!(group_status_priority(&[S::Completed]), S::Completed);
        assert_eq!(group_status_priority(&[]), S::Completed);
    }

    #[test]
    fn transfer_groups_aggregates_grouped_tasks_and_ignores_ungrouped() {
        let _test_guard = global_test_lock();
        let mk = |group: Option<(&str, &str)>, status: TransferStatusEnum, size: u64, done: u64| {
            let mut task = make_test_task(Uuid::new_v4());
            if let Some((gid, gname)) = group {
                task.group_id = Some(gid.into());
                task.group_name = Some(gname.into());
            }
            task.direction = TransferDirectionEnum::Download;
            task.size = size;
            *task.status.lock().unwrap() = status;
            task.transferred.store(done, Ordering::Relaxed);
            task
        };

        let running = mk(Some(("g1", "备份")), TransferStatusEnum::Running, 100, 10);
        let done = mk(
            Some(("g1", "备份")),
            TransferStatusEnum::Completed,
            200,
            200,
        );
        let cancelled = mk(Some(("g2", "同步")), TransferStatusEnum::Cancelled, 50, 0);
        let lone = mk(None, TransferStatusEnum::Running, 10, 0);
        for t in [&running, &done, &cancelled, &lone] {
            insert_test_task(t);
        }

        let groups = transfer_groups().unwrap();
        assert_eq!(groups.len(), 2, "无分组任务不应出现在聚合中");
        assert!(groups[0].group_name < groups[1].group_name, "应按组名排序");

        let backup = groups.iter().find(|g| g.group_name == "备份").unwrap();
        assert_eq!(backup.group_id, "g1");
        assert_eq!(backup.total_count, 2);
        assert_eq!(backup.completed_count, 1);
        assert_eq!(backup.total_bytes, 300);
        assert_eq!(backup.transferred_bytes, 210);
        assert_eq!(
            backup.status,
            TransferStatusEnum::Running,
            "running 优先于 completed"
        );
        assert!(
            matches!(backup.direction, TransferDirectionEnum::Download),
            "组方向应取首个成员的方向"
        );

        let sync = groups.iter().find(|g| g.group_name == "同步").unwrap();
        assert_eq!(sync.status, TransferStatusEnum::Cancelled);

        for t in [&running, &done, &cancelled, &lone] {
            remove_test_task(&t.id);
        }
    }

    // -----------------------------------------------------------------------
    // 暂停等待与任务执行
    // -----------------------------------------------------------------------

    #[test]
    fn wait_while_paused_blocks_until_resume_and_reports_paused_status() {
        let _test_guard = global_test_lock();
        let task = make_test_task(Uuid::new_v4());
        task.paused.store(true, Ordering::Relaxed);
        let handle = runtime().spawn({
            let t = task.clone();
            async move {
                wait_while_paused(&t).await;
            }
        });

        let mut paused_seen = false;
        for _ in 0..100 {
            if *task.status.lock().unwrap() == TransferStatusEnum::Paused {
                paused_seen = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(paused_seen, "暂停中的任务应被标记为 Paused");

        task.paused.store(false, Ordering::Relaxed);
        task.resume_notify.notify_waiters();
        runtime().block_on(handle).unwrap();
        assert_ne!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Cancelled,
            "恢复后的等待应正常返回且不改变状态"
        );
    }

    #[test]
    fn wait_while_paused_returns_immediately_when_cancelled() {
        let _test_guard = global_test_lock();
        // 取消标志优先于暂停：等待立即返回且不改状态
        let task = make_test_task(Uuid::new_v4());
        task.cancel.store(true, Ordering::Relaxed);
        task.paused.store(true, Ordering::Relaxed);
        runtime().block_on(wait_while_paused(&task));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Queued);

        // 状态已是 Cancelled 时也直接返回
        let task2 = make_test_task(Uuid::new_v4());
        *task2.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        task2.paused.store(true, Ordering::Relaxed);
        runtime().block_on(wait_while_paused(&task2));
        assert_eq!(*task2.status.lock().unwrap(), TransferStatusEnum::Cancelled);
    }

    /// 指向本机未监听端口的主机配置：连接会被立即拒绝，不产生真实网络流量。
    fn refused_host_config() -> panda_core::HostConfig {
        panda_core::HostConfig {
            id: "refused-host".into(),
            name: "拒绝连接".into(),
            host: "127.0.0.1".into(),
            port: 1,
            username: "deploy".into(),
            auth: panda_core::AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        }
    }

    #[test]
    fn run_transfer_task_marks_cancelled_before_and_after_semaphore() {
        let _test_guard = global_test_lock();
        let cfg = refused_host_config();

        // 排队阶段已设置取消标志：不获取信号量直接标 Cancelled
        let task = make_test_task(Uuid::new_v4());
        task.cancel.store(true, Ordering::Relaxed);
        insert_test_task(&task);
        runtime().block_on(run_transfer_task(task.clone(), cfg.clone()));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Cancelled);
        remove_test_task(&task.id);

        // 获取信号量后状态已是 Cancelled：不再进入 Running
        let task2 = make_test_task(Uuid::new_v4());
        *task2.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        insert_test_task(&task2);
        runtime().block_on(run_transfer_task(task2.clone(), cfg));
        assert_eq!(*task2.status.lock().unwrap(), TransferStatusEnum::Cancelled);
        remove_test_task(&task2.id);
    }

    #[test]
    fn run_transfer_task_marks_failed_when_connection_is_refused() {
        let _test_guard = global_test_lock();
        // 上传方向：连接被拒绝 → Failed 且携带错误信息
        let mut task = make_test_task(Uuid::new_v4());
        task.password = Some("pw".into());
        insert_test_task(&task);
        runtime().block_on(run_transfer_task(task.clone(), refused_host_config()));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Failed);
        assert!(task.error.lock().unwrap().is_some());
        remove_test_task(&task.id);

        // 下载方向同样落到 Failed
        let mut download = make_test_task(Uuid::new_v4());
        download.direction = TransferDirectionEnum::Download;
        download.password = Some("pw".into());
        insert_test_task(&download);
        runtime().block_on(run_transfer_task(download.clone(), refused_host_config()));
        assert_eq!(*download.status.lock().unwrap(), TransferStatusEnum::Failed);
        assert!(download.error.lock().unwrap().is_some());
        remove_test_task(&download.id);
    }

    // -----------------------------------------------------------------------
    // 重试、暂停拒绝
    // -----------------------------------------------------------------------

    #[test]
    fn transfer_retry_rejects_non_retryable_and_unknown_tasks() {
        let _test_guard = global_test_lock();
        // 不存在的任务
        assert!(matches!(
            transfer_retry(Uuid::new_v4().to_string()),
            Err(PandaError::UnknownTransferTask(_))
        ));

        // 非 UUID id → 结构化解析错误
        assert!(transfer_retry("not-a-uuid".into()).is_err());

        // 非重试状态（Queued）→ 拒绝
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);
        let error = transfer_retry(id.to_string()).unwrap_err();
        assert!(error.to_string().contains("not in a retryable state"));
        remove_test_task(&id);
    }

    #[test]
    fn transfer_retry_resets_state_and_reruns_until_terminal() {
        // 重试会重新加载主机配置：持有统一全局测试锁并初始化测试目录
        let _test_guard = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        crate::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
        let mut record: crate::HostConfigRecord = refused_host_config().into();
        record.id = "refused-host".into();
        crate::save_host(record).unwrap();

        let id = Uuid::new_v4();
        let mut task = make_test_task(id);
        task.host_id = "refused-host".into();
        task.password = Some("pw".into());
        *task.status.lock().unwrap() = TransferStatusEnum::Failed;
        *task.error.lock().unwrap() = Some("上次失败".into());
        insert_test_task(&task);

        let version_before = task.version.load(Ordering::Relaxed);
        // 占满并发槽位，稳定验证重试后在真正获准执行前保持 Queued。
        // 若不这样做，后台任务可能在下一个断言前已抢到许可证并进入 Running。
        let permits = runtime()
            .block_on(transfer_semaphore().acquire_many(TRANSFER_CONCURRENCY as u32))
            .unwrap();
        let retried = transfer_retry(id.to_string()).unwrap();
        assert_eq!(retried, id.to_string());
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Queued,
            "重试应重置为排队"
        );
        assert!(task.error.lock().unwrap().is_none(), "重试应清空上次错误");
        assert!(task.version.load(Ordering::Relaxed) > version_before);

        // 重试后的任务会真正执行并因连接被拒绝进入 Failed 终态
        drop(permits);
        let mut terminal = false;
        for _ in 0..300 {
            if *task.status.lock().unwrap() == TransferStatusEnum::Failed {
                terminal = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(terminal, "重试后任务应因连接拒绝进入 Failed");
        assert!(task.error.lock().unwrap().is_some());
        remove_test_task(&id);
    }

    #[test]
    fn transfer_pause_rejects_terminal_task_and_resume_is_noop_for_it() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Failed;
        insert_test_task(&task);

        let error = transfer_pause(id.to_string()).unwrap_err();
        assert!(error.to_string().contains("already terminal"));

        // 终态任务的 resume 也是 no-op：状态保持不变
        transfer_resume(id.to_string()).unwrap();
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Failed);
        remove_test_task(&id);
    }
}
