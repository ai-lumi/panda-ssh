//! 批量 SFTP 传输的 FFI 暴露。
//!
//! 与单文件传输独立：使用单独的注册表，避免改动现有 TransferTask 结构。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use panda_core::{
    execute_batch_download, execute_batch_upload, scan_local_sources, scan_remote_sources,
    BatchTransferOptions, ConflictResolution, Credentials, KnownHosts, SftpClient, SshSession,
    UnknownHostKeyPolicy,
};
use uuid::Uuid;

use crate::{load_host, runtime, stores, PandaError};

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// 批量传输方向。
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum BatchTransferDirectionEnum {
    Upload,
    Download,
}

/// 批量传输任务状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BatchTransferStatusEnum {
    Queued,
    Running,
    /// 单个目标文件已存在，暂停等待 UI 覆盖确认。
    WaitingForConflict,
    Completed,
    Failed,
    Cancelled,
}

/// 批量传输中单个文件的覆盖确认信息。
/// 与单文件传输的 `RemoteFileConflictRecord` 同构，额外携带源/目标路径。
#[derive(Debug, Clone, uniffi::Record)]
pub struct BatchConflictRecord {
    pub item_source: String,
    pub item_destination: String,
    pub source_size: u64,
    pub source_mtime: Option<u64>,
    pub target_size: u64,
    pub target_mtime: Option<u64>,
}

/// FFI-friendly snapshot of a batch transfer task.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BatchTransferStatusRecord {
    pub id: String,
    pub direction: BatchTransferDirectionEnum,
    pub host_id: String,
    pub dest_dir: String,
    pub sources: Vec<String>,
    pub total_size: u64,
    pub transferred: u64,
    pub status: BatchTransferStatusEnum,
    pub error: Option<String>,
    /// 等待覆盖确认时的冲突信息；其余状态为 None。
    pub pending_conflict: Option<BatchConflictRecord>,
}

/// FFI-friendly single item in a batch scan result.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BatchItemRecord {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub is_dir: bool,
}

// ---------------------------------------------------------------------------
// Internal task record
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct BatchTransferTask {
    id: Uuid,
    direction: BatchTransferDirectionEnum,
    host_id: String,
    dest_dir: String,
    sources: Vec<String>,
    password: Option<String>,
    passphrase: Option<String>,
    total_size: Arc<AtomicU64>,
    transferred: Arc<AtomicU64>,
    status: Arc<Mutex<BatchTransferStatusEnum>>,
    error: Arc<Mutex<Option<String>>>,
    cancel: Arc<AtomicBool>,
    /// 等待覆盖确认时对外暴露的冲突信息。
    pending_conflict: Arc<Mutex<Option<BatchConflictRecord>>>,
    /// 冲突决策回传通道：Swift 调用 `batch_transfer_resolve_conflict` 时经此发送。
    conflict_tx: Arc<Mutex<Option<std::sync::mpsc::Sender<ConflictResolution>>>>,
}

impl BatchTransferTask {
    fn snapshot(&self) -> BatchTransferStatusRecord {
        BatchTransferStatusRecord {
            id: self.id.to_string(),
            direction: self.direction,
            host_id: self.host_id.clone(),
            dest_dir: self.dest_dir.clone(),
            sources: self.sources.clone(),
            total_size: self.total_size.load(Ordering::Relaxed),
            transferred: self.transferred.load(Ordering::Relaxed),
            status: *self.status.lock().unwrap(),
            error: self.error.lock().unwrap().clone(),
            pending_conflict: self.pending_conflict.lock().unwrap().clone(),
        }
    }
}

static BATCH_TRANSFER_TASKS: OnceLock<Mutex<HashMap<Uuid, BatchTransferTask>>> = OnceLock::new();

fn batch_transfer_tasks() -> &'static Mutex<HashMap<Uuid, BatchTransferTask>> {
    BATCH_TRANSFER_TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

// ---------------------------------------------------------------------------
// Public FFI API
// ---------------------------------------------------------------------------

/// Start a batch upload task. `sources` are local paths; `dest_dir` is the remote target directory.
#[uniffi::export]
pub fn start_batch_upload(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    start_batch_transfer(
        BatchTransferDirectionEnum::Upload,
        host_id,
        sources,
        dest_dir,
        password,
        passphrase,
    )
}

/// Start a batch download task. `sources` are remote paths; `dest_dir` is the local target directory.
#[uniffi::export]
pub fn start_batch_download(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    start_batch_transfer(
        BatchTransferDirectionEnum::Download,
        host_id,
        sources,
        dest_dir,
        password,
        passphrase,
    )
}

/// Scan local sources and return the flattened list of items (files and directories)
/// with their destination paths under `dest_dir`.
#[uniffi::export]
pub fn scan_local_batch(
    sources: Vec<String>,
    dest_dir: String,
) -> Result<Vec<BatchItemRecord>, PandaError> {
    runtime().block_on(async {
        let paths: Vec<PathBuf> = sources.iter().map(PathBuf::from).collect();
        let plan = scan_local_sources(&paths, &dest_dir, &Default::default()).await?;
        Ok(plan
            .items
            .into_iter()
            .map(|item| BatchItemRecord {
                source: item.source,
                destination: item.destination,
                size: item.size,
                is_dir: item.is_dir,
            })
            .collect())
    })
}

/// Scan remote sources and return the flattened list of items (files and directories)
/// with their destination paths under `dest_dir`.
#[uniffi::export]
pub fn scan_remote_batch(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<Vec<BatchItemRecord>, PandaError> {
    let cfg = load_host(&host_id)?;
    runtime().block_on(async {
        let creds = credentials_for(&cfg, password.clone(), passphrase.clone())
            .map_err(|e| PandaError::Core(e))?;
        let store_path = stores()?.known_hosts.path().to_path_buf();
        let mut known_hosts = KnownHosts::new(store_path);
        let session = SshSession::connect_shared(
            &cfg,
            creds,
            &mut known_hosts,
            UnknownHostKeyPolicy::AcceptAndStore,
        )
        .await?;
        session.set_owner("批量扫描", host_id.clone());
        let sftp = SftpClient::new(&session).await?;
        let plan = scan_remote_sources(&sftp, &sources, &dest_dir, &Default::default()).await?;
        let _ = sftp.close().await;
        Ok(plan
            .items
            .into_iter()
            .map(|item| BatchItemRecord {
                source: item.source,
                destination: item.destination,
                size: item.size,
                is_dir: item.is_dir,
            })
            .collect())
    })
}

fn start_batch_transfer(
    direction: BatchTransferDirectionEnum,
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    let id = Uuid::new_v4();
    let task = BatchTransferTask {
        id,
        direction,
        host_id,
        dest_dir,
        sources,
        password,
        passphrase,
        total_size: Arc::new(AtomicU64::new(0)),
        transferred: Arc::new(AtomicU64::new(0)),
        status: Arc::new(Mutex::new(BatchTransferStatusEnum::Queued)),
        error: Arc::new(Mutex::new(None)),
        cancel: Arc::new(AtomicBool::new(false)),
        pending_conflict: Arc::new(Mutex::new(None)),
        conflict_tx: Arc::new(Mutex::new(None)),
    };
    batch_transfer_tasks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, task.clone());

    runtime().spawn(async move {
        run_batch_transfer_task(task, cfg).await;
    });
    Ok(id.to_string())
}

async fn run_batch_transfer_task(task: BatchTransferTask, cfg: panda_core::HostConfig) {
    {
        let mut status = task.status.lock().unwrap();
        if *status == BatchTransferStatusEnum::Cancelled {
            return;
        }
        *status = BatchTransferStatusEnum::Running;
    }

    let creds = match credentials_for(&cfg, task.password.clone(), task.passphrase.clone()) {
        Ok(c) => c,
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e);
            return;
        }
    };

    let store_path = match stores() {
        Ok(s) => s.known_hosts.path().to_path_buf(),
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e.to_string());
            return;
        }
    };
    let mut known_hosts = KnownHosts::new(store_path);
    let session = match SshSession::connect_shared(
        &cfg,
        creds,
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await
    {
        Ok(s) => s,
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e.to_string());
            return;
        }
    };
    session.set_owner("批量传输", task.id.to_string());
    let sftp = match SftpClient::new(&session).await {
        Ok(s) => s,
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e.to_string());
            return;
        }
    };

    let options = BatchTransferOptions::default();
    // 目标已存在时暂停该文件，向 Swift 暴露冲突信息并等待决策；
    // Swift 调用 batch_transfer_resolve_conflict 回传覆盖/跳过。
    let pending_conflict = task.pending_conflict.clone();
    let conflict_tx = task.conflict_tx.clone();
    let task_status = task.status.clone();
    let conflict_cb = Arc::new(
        move |item: &panda_core::BatchItem, info: &panda_core::FileConflictInfo| {
            // 记录冲突信息并进入等待状态，供 Swift 轮询呈现。
            *pending_conflict.lock().unwrap() = Some(BatchConflictRecord {
                item_source: item.source.clone(),
                item_destination: item.destination.clone(),
                source_size: info.source_size,
                source_mtime: info.source_mtime,
                target_size: info.target_size,
                target_mtime: info.target_mtime,
            });
            *task_status.lock().unwrap() = BatchTransferStatusEnum::WaitingForConflict;

            // 创建一次性决策通道；batch_transfer_resolve_conflict / cancel 经此回传。
            let rx = {
                let (tx, rx) = std::sync::mpsc::channel();
                *conflict_tx.lock().unwrap() = Some(tx);
                rx
            };
            // 同步等待决策；取消由 cancel 发 Skip 唤醒，超时兜底按跳过处理。
            match rx.recv_timeout(Duration::from_secs(300)) {
                Ok(ConflictResolution::Overwrite) => ConflictResolution::Overwrite,
                Ok(ConflictResolution::Skip) | Err(_) => ConflictResolution::Skip,
            }
        },
    );

    let scan_result = match task.direction {
        BatchTransferDirectionEnum::Upload => {
            let paths: Vec<PathBuf> = task.sources.iter().map(PathBuf::from).collect();
            scan_local_sources(&paths, &task.dest_dir, &Default::default()).await
        }
        BatchTransferDirectionEnum::Download => {
            scan_remote_sources(&sftp, &task.sources, &task.dest_dir, &Default::default()).await
        }
    };

    let plan = match scan_result {
        Ok(plan) => {
            task.total_size.store(plan.total_size, Ordering::Relaxed);
            plan
        }
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e.to_string());
            let _ = sftp.close().await;
            return;
        }
    };

    let transferred = task.transferred.clone();
    let progress = Arc::new(move |done: u64, _total: u64| {
        transferred.store(done, Ordering::Relaxed);
    });

    let outcome = match task.direction {
        BatchTransferDirectionEnum::Upload => {
            execute_batch_upload(
                &sftp,
                &plan,
                &options,
                Some(conflict_cb),
                Some(progress),
                Some(task.cancel.clone()),
            )
            .await
        }
        BatchTransferDirectionEnum::Download => {
            execute_batch_download(
                &sftp,
                &plan,
                &options,
                Some(conflict_cb),
                Some(progress),
                Some(task.cancel.clone()),
            )
            .await
        }
    };

    let _ = sftp.close().await;

    match outcome {
        Ok(outcome) => {
            // 等待覆盖确认期间被取消：即使最后一项刚被跳过，也以取消收尾。
            if outcome.cancelled || task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Cancelled;
            } else if !outcome.errors.is_empty() {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
                *task.error.lock().unwrap() = Some(outcome.errors.join("; "));
            } else {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Completed;
                task.transferred
                    .store(task.total_size.load(Ordering::Relaxed), Ordering::Relaxed);
            }
        }
        Err(e) => {
            if task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Cancelled;
            } else {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
                *task.error.lock().unwrap() = Some(e.to_string());
            }
        }
    }
}

fn credentials_for(
    cfg: &panda_core::HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<Credentials, String> {
    crate::credentials_for(cfg, password, passphrase).map_err(|e| e.to_string())
}

/// Get a single batch task's current status.
#[uniffi::export]
pub fn batch_transfer_status(task_id: String) -> Result<BatchTransferStatusRecord, PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let tasks = batch_transfer_tasks().lock().unwrap();
    let task = tasks
        .get(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    Ok(task.snapshot())
}

/// List all batch tasks ordered by id.
#[uniffi::export]
pub fn batch_transfer_list() -> Result<Vec<BatchTransferStatusRecord>, PandaError> {
    let tasks = batch_transfer_tasks().lock().unwrap();
    let mut records: Vec<_> = tasks.values().map(|t| t.snapshot()).collect();
    records.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(records)
}

/// Cancel a queued, running or conflict-waiting batch task.
/// 若任务正等待覆盖确认，唤醒等待者（按跳过处理）后由取消标志终止。
#[uniffi::export]
pub fn batch_transfer_cancel(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = batch_transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.cancel.store(true, Ordering::Relaxed);
    // 正在等待覆盖确认：唤醒等待者（发送 Skip），执行循环将在下一轮检测取消。
    if let Some(tx) = task.conflict_tx.lock().unwrap().take() {
        let _ = tx.send(ConflictResolution::Skip);
    }
    let status = *task.status.lock().unwrap();
    if status == BatchTransferStatusEnum::Queued {
        *task.status.lock().unwrap() = BatchTransferStatusEnum::Cancelled;
    }
    Ok(())
}

/// 回传批量任务中单个冲突文件的覆盖决策。
/// `overwrite=true` 覆盖写入；`false` 跳过该项目。任务随后继续处理后续项目。
/// 仅对处于 `WaitingForConflict` 状态的任务有效。
#[uniffi::export]
pub fn batch_transfer_resolve_conflict(task_id: String, overwrite: bool) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let task = {
        let tasks = batch_transfer_tasks().lock().unwrap();
        tasks
            .get(&id)
            .cloned()
            .ok_or_else(|| PandaError::UnknownTransferTask(task_id.clone()))?
    };
    {
        let status = *task.status.lock().unwrap();
        if !matches!(status, BatchTransferStatusEnum::WaitingForConflict) {
            return Err(PandaError::Core(
                "batch task is not waiting for a conflict decision".to_string(),
            ));
        }
    }
    // 取出一次性决策通道并回传决策；失败说明等待者已消失（如被取消）。
    let tx = task
        .conflict_tx
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| PandaError::Core("no pending conflict decision channel".to_string()))?;
    let decision = if overwrite {
        ConflictResolution::Overwrite
    } else {
        ConflictResolution::Skip
    };
    tx.send(decision)
        .map_err(|_| PandaError::Core("conflict decision channel closed".to_string()))?;
    // 清空待确认信息并回到 Running，任务继续执行。
    *task.pending_conflict.lock().unwrap() = None;
    *task.status.lock().unwrap() = BatchTransferStatusEnum::Running;
    Ok(())
}
