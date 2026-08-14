//! 批量 SFTP 传输的 FFI 暴露。
//!
//! 与单文件传输独立：使用单独的注册表，避免改动现有 TransferTask 结构。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use panda_core::{
    execute_batch_download, execute_batch_upload, scan_local_sources, scan_remote_sources,
    BatchTransferOptions, ConflictResolution, Credentials, KnownHosts, SftpClient,
    UnknownHostKeyPolicy,
};
use panda_core::connection_pool;
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
    Completed,
    Failed,
    Cancelled,
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
pub fn scan_local_batch(sources: Vec<String>, dest_dir: String) -> Result<Vec<BatchItemRecord>, PandaError> {
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
        let session = connection_pool::global_pool()
            .get_or_create(
                host_id.clone(),
                &cfg,
                creds,
                &mut known_hosts,
                UnknownHostKeyPolicy::AcceptAndStore,
            )
            .await?;
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
    let session = match connection_pool::global_pool()
        .get_or_create(
            task.host_id.clone(),
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
    let sftp = match SftpClient::new(&session).await {
        Ok(s) => s,
        Err(e) => {
            *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some(e.to_string());
            return;
        }
    };

    let options = BatchTransferOptions::default();
    // 默认覆盖已存在目标；后续可通过新增 resolve_conflict FFI 改为暂停确认。
    let conflict_cb = Arc::new(|_item: &panda_core::BatchItem, _info: &panda_core::FileConflictInfo| {
        ConflictResolution::Overwrite
    });

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
            if outcome.cancelled {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Cancelled;
            } else if !outcome.errors.is_empty() {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Failed;
                *task.error.lock().unwrap() = Some(outcome.errors.join("; "));
            } else {
                *task.status.lock().unwrap() = BatchTransferStatusEnum::Completed;
                task.transferred.store(task.total_size.load(Ordering::Relaxed), Ordering::Relaxed);
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

/// Cancel a queued or running batch task.
#[uniffi::export]
pub fn batch_transfer_cancel(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = batch_transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.cancel.store(true, Ordering::Relaxed);
    let status = *task.status.lock().unwrap();
    if status == BatchTransferStatusEnum::Queued {
        *task.status.lock().unwrap() = BatchTransferStatusEnum::Cancelled;
    }
    Ok(())
}
