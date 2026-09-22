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
#[path = "tests/ffi_transfers_tests.rs"]
mod tests;
