//! 批量 SFTP 传输的 FFI 薄桥。
//!
//! 业务逻辑已全部迁入 `panda_core::batch::BatchTransferService`；
//! 本模块仅负责类型转换、全局服务生命周期和实际 SSH/SFTP 执行。

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use panda_core::{
    execute_batch_download, execute_batch_upload, scan_local_sources, scan_remote_sources,
    BatchConflictInfo, BatchContext, BatchDirection, BatchExecutor, BatchOutcome, BatchServiceParams,
    BatchStatus, BatchTaskSnapshot, BatchTransferOptions, BatchTransferService,
    FileConflictInfo, KnownHosts, SftpClient, SshSession, UnknownHostKeyPolicy,
};

use super::notify_transfer_changed;
use crate::ffi_runtime::runtime;
use crate::ffi_store::{credentials_for as store_credentials_for, load_host, stores};
use crate::PandaError;

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// 批量传输方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BatchTransferDirectionEnum {
    Upload,
    Download,
}

/// 批量传输任务状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BatchTransferStatusEnum {
    Queued,
    Running,
    WaitingForConflict,
    Completed,
    Failed,
    Cancelled,
}

/// 批量传输中单个文件的覆盖确认信息。
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
// Type conversions
// ---------------------------------------------------------------------------

#[cfg(test)]
fn to_core_direction(d: BatchTransferDirectionEnum) -> BatchDirection {
    match d {
        BatchTransferDirectionEnum::Upload => BatchDirection::Upload,
        BatchTransferDirectionEnum::Download => BatchDirection::Download,
    }
}

fn from_core_direction(d: BatchDirection) -> BatchTransferDirectionEnum {
    match d {
        BatchDirection::Upload => BatchTransferDirectionEnum::Upload,
        BatchDirection::Download => BatchTransferDirectionEnum::Download,
    }
}

fn from_core_status(s: BatchStatus) -> BatchTransferStatusEnum {
    match s {
        BatchStatus::Queued => BatchTransferStatusEnum::Queued,
        BatchStatus::Running => BatchTransferStatusEnum::Running,
        BatchStatus::WaitingForConflict => BatchTransferStatusEnum::WaitingForConflict,
        BatchStatus::Completed => BatchTransferStatusEnum::Completed,
        BatchStatus::Failed => BatchTransferStatusEnum::Failed,
        BatchStatus::Cancelled => BatchTransferStatusEnum::Cancelled,
    }
}

fn from_core_conflict(info: BatchConflictInfo) -> BatchConflictRecord {
    BatchConflictRecord {
        item_source: info.item_source,
        item_destination: info.item_destination,
        source_size: info.source_size,
        source_mtime: info.source_mtime,
        target_size: info.target_size,
        target_mtime: info.target_mtime,
    }
}

fn snapshot_to_record(s: BatchTaskSnapshot) -> BatchTransferStatusRecord {
    BatchTransferStatusRecord {
        id: s.id,
        direction: from_core_direction(s.direction),
        host_id: s.host_id,
        dest_dir: s.dest_dir,
        sources: s.sources,
        total_size: s.total_size,
        transferred: s.transferred,
        status: from_core_status(s.status),
        error: s.error,
        pending_conflict: s.pending_conflict.map(from_core_conflict),
    }
}

// ---------------------------------------------------------------------------
// FFI executor — 实际 SSH/SFTP 连接 + 扫描 + 传输
// ---------------------------------------------------------------------------

struct FfiBatchExecutor;

impl BatchExecutor for FfiBatchExecutor {
    fn execute(&self, ctx: &BatchContext) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
        let host_id = ctx.host_id.clone();
        let sources = ctx.sources.clone();
        let dest_dir = ctx.dest_dir.clone();
        let password = ctx.password.clone();
        let passphrase = ctx.passphrase.clone();
        let direction = ctx.direction;
        let progress = ctx.progress.clone();
        let cancel = ctx.cancel.clone();
        let conflict_resolver = ctx.conflict.clone();

        Box::pin(async move {
            let cfg = match load_host(&host_id) {
                Ok(c) => c,
                Err(e) => {
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    }
                }
            };
            let creds = match store_credentials_for(&cfg, password, passphrase) {
                Ok(c) => c,
                Err(e) => {
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    }
                }
            };
            let store_path = match stores() {
                Ok(s) => s.core.known_hosts_store().path().to_path_buf(),
                Err(e) => {
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    }
                }
            };
            let mut known_hosts = KnownHosts::new(store_path);
            let session = match SshSession::connect_shared(
                &cfg,
                creds,
                &mut known_hosts,
                UnknownHostKeyPolicy::Reject,
            )
            .await
            {
                Ok(s) => s,
                Err(e) => {
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    }
                }
            };
            session.set_owner("批量传输", host_id.clone());
            let sftp = match SftpClient::new(&session).await {
                Ok(s) => s,
                Err(e) => {
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    }
                }
            };

            let resolver = conflict_resolver.clone();
            let conflict_cb: panda_core::BatchConflictCallback = Arc::new(
                move |item: &panda_core::BatchItem, info: &FileConflictInfo| {
                    resolver.set_pending(BatchConflictInfo {
                        item_source: item.source.clone(),
                        item_destination: item.destination.clone(),
                        source_size: info.source_size,
                        source_mtime: info.source_mtime,
                        target_size: info.target_size,
                        target_mtime: info.target_mtime,
                    });
                    let resolution = tokio::task::block_in_place(|| {
                        tokio::runtime::Handle::current().block_on(resolver.resolve())
                    });
                    resolver.clear_pending();
                    resolution
                },
            );

            let scan_result = match direction {
                BatchDirection::Upload => {
                    let paths: Vec<PathBuf> = sources.iter().map(PathBuf::from).collect();
                    scan_local_sources(&paths, &dest_dir, &Default::default()).await
                }
                BatchDirection::Download => {
                    scan_remote_sources(&sftp, &sources, &dest_dir, &Default::default()).await
                }
            };

            let plan = match scan_result {
                Ok(p) => p,
                Err(e) => {
                    let _ = sftp.close().await;
                    return BatchOutcome {
                        completed: vec![],
                        skipped: vec![],
                        errors: vec![e.to_string()],
                        cancelled: false,
                    };
                }
            };

            progress(0, plan.total_size);

            let options = BatchTransferOptions::default();
            let outcome = match direction {
                BatchDirection::Upload => {
                    execute_batch_upload(
                        &sftp,
                        &plan,
                        &options,
                        Some(conflict_cb),
                        Some(progress),
                        Some(cancel),
                    )
                    .await
                }
                BatchDirection::Download => {
                    execute_batch_download(
                        &sftp,
                        &plan,
                        &options,
                        Some(conflict_cb),
                        Some(progress),
                        Some(cancel),
                    )
                    .await
                }
            };

            let _ = sftp.close().await;
            match outcome {
                Ok(o) => o,
                Err(e) => BatchOutcome {
                    completed: vec![],
                    skipped: vec![],
                    errors: vec![e.to_string()],
                    cancelled: false,
                },
            }
        })
    }
}

// ---------------------------------------------------------------------------
// Global service state
// ---------------------------------------------------------------------------

static BATCH_SERVICE: Mutex<Option<BatchTransferService>> = Mutex::new(None);

pub(super) fn batch_service() -> BatchTransferService {
    let mut guard = BATCH_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(ref svc) = *guard {
        return svc.clone();
    }
    let params = BatchServiceParams {
        conflict_timeout: std::time::Duration::from_secs(300),
        on_change: Some(Arc::new(|| {
            notify_transfer_changed();
        })),
    };
    let svc = BatchTransferService::with_params(Box::new(FfiBatchExecutor), params);
    *guard = Some(svc.clone());
    svc
}

// ---------------------------------------------------------------------------
// FFI exports — 薄代理至核心 BatchTransferService
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn start_batch_upload(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    let _cfg = load_host(&host_id)?;
    let svc = batch_service();
    runtime()
        .block_on(async { svc.start_upload(host_id, sources, dest_dir, password, passphrase) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn start_batch_download(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    let _cfg = load_host(&host_id)?;
    let svc = batch_service();
    runtime()
        .block_on(async { svc.start_download(host_id, sources, dest_dir, password, passphrase) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn scan_local_batch(
    sources: Vec<String>,
    dest_dir: String,
) -> Result<Vec<BatchItemRecord>, PandaError> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    runtime().spawn(async move {
        let result = async {
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
        }
        .await;
        let _ = tx.send(result);
    });
    rx.blocking_recv()
        .map_err(|_| PandaError::Core("scan_local_batch: task dropped".into()))?
}

#[uniffi::export]
pub fn scan_remote_batch(
    host_id: String,
    sources: Vec<String>,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<Vec<BatchItemRecord>, PandaError> {
    let cfg = load_host(&host_id)?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    runtime().spawn(async move {
        let result = async {
            let creds = store_credentials_for(&cfg, password.clone(), passphrase.clone())?;
            let store_path = stores()?.core.known_hosts_store().path().to_path_buf();
            let mut known_hosts = KnownHosts::new(store_path);
            let session = SshSession::connect_shared(
                &cfg,
                creds,
                &mut known_hosts,
                UnknownHostKeyPolicy::Reject,
            )
            .await?;
            session.set_owner("批量扫描", host_id.clone());
            let sftp = SftpClient::new(&session).await?;
            let plan =
                scan_remote_sources(&sftp, &sources, &dest_dir, &Default::default()).await?;
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
        }
        .await;
        let _ = tx.send(result);
    });
    rx.blocking_recv()
        .map_err(|_| PandaError::Core("scan_remote_batch: task dropped".into()))?
}

#[uniffi::export]
pub fn batch_transfer_status(
    task_id: String,
) -> Result<BatchTransferStatusRecord, PandaError> {
    let snap = batch_service()
        .status(&task_id)
        .map_err(|e| {
            let msg = e.to_string();
            if msg.contains("未知任务") || msg.contains("无效任务") {
                PandaError::UnknownTransferTask(task_id.clone())
            } else {
                PandaError::Core(msg)
            }
        })?;
    Ok(snapshot_to_record(snap))
}

#[uniffi::export]
pub fn batch_transfer_list() -> Result<Vec<BatchTransferStatusRecord>, PandaError> {
    let list = batch_service().list();
    Ok(list.into_iter().map(snapshot_to_record).collect())
}

#[uniffi::export]
pub fn batch_transfer_cancel(task_id: String) -> Result<(), PandaError> {
    batch_service()
        .cancel(&task_id)
        .map_err(|e| {
            let msg = e.to_string();
            if msg.contains("未知任务") || msg.contains("无效任务") {
                PandaError::UnknownTransferTask(task_id.clone())
            } else {
                PandaError::Core(msg)
            }
        })
}

#[uniffi::export]
pub fn batch_transfer_resolve_conflict(
    task_id: String,
    overwrite: bool,
) -> Result<(), PandaError> {
    batch_service()
        .resolve_conflict(&task_id, overwrite)
        .map_err(|e| {
            let msg = e.to_string();
            if msg.contains("未知任务") || msg.contains("无效任务") {
                PandaError::UnknownTransferTask(task_id.clone())
            } else {
                PandaError::Core(msg)
            }
        })
}

/// 测试用：重置全局批量服务。
#[cfg(test)]
pub(crate) fn reset_batch_service_for_test() {
    let mut guard = BATCH_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *guard = None;
}

#[cfg(test)]
#[path = "tests/batch_transfer_tests.rs"]
mod tests;
