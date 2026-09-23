//! 传输域 FFI 导出：单文件/批量任务、聚合。
//!
//! 单文件传输逻辑已迁入 `panda_core::transfer::TransferService`；
//! 本模块仅负责类型转换、全局服务生命周期和实际 SSH/SFTP 执行。

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

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use panda_core::transfer::{
    TransferDirection, TransferExecutor, TransferParams, TransferService, TransferSnapshot,
    TransferStatus,
};
use panda_core::sftp_orchestration::{
    plan_sftp_orchestration, SftpOrchestrationDirection,
};
use panda_core::{KnownHosts, SftpClient, SshSession, UnknownHostKeyPolicy};

use crate::ffi_runtime::runtime;
use crate::ffi_store::{credentials_for, load_host, stores};
use crate::PandaError;

// ---------------------------------------------------------------------------
// Exported types (UniFFI)
// ---------------------------------------------------------------------------

const TRANSFER_CONCURRENCY: usize = 3;

/// Direction of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
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
    pub version: u64,
    pub speed: f64,
    pub total_speed: f64,
    pub eta_seconds: Option<f64>,
    pub group_id: Option<String>,
    pub group_name: Option<String>,
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

// ---------------------------------------------------------------------------
// Type conversions
// ---------------------------------------------------------------------------

fn to_core_direction(d: TransferDirectionEnum) -> TransferDirection {
    match d {
        TransferDirectionEnum::Upload => TransferDirection::Upload,
        TransferDirectionEnum::Download => TransferDirection::Download,
    }
}

fn from_core_direction(d: TransferDirection) -> TransferDirectionEnum {
    match d {
        TransferDirection::Upload => TransferDirectionEnum::Upload,
        TransferDirection::Download => TransferDirectionEnum::Download,
    }
}

fn from_core_status(s: TransferStatus) -> TransferStatusEnum {
    match s {
        TransferStatus::Queued => TransferStatusEnum::Queued,
        TransferStatus::Running => TransferStatusEnum::Running,
        TransferStatus::Paused => TransferStatusEnum::Paused,
        TransferStatus::Completed => TransferStatusEnum::Completed,
        TransferStatus::Failed => TransferStatusEnum::Failed,
        TransferStatus::Cancelled => TransferStatusEnum::Cancelled,
    }
}

fn snapshot_to_record(s: TransferSnapshot) -> TransferStatusRecord {
    TransferStatusRecord {
        id: s.id,
        direction: from_core_direction(s.direction),
        host_id: s.host_id,
        local_path: s.local_path,
        remote_path: s.remote_path,
        size: s.size,
        transferred: s.transferred,
        status: from_core_status(s.status),
        error: s.error,
        version: s.version,
        speed: s.speed,
        total_speed: s.total_speed,
        eta_seconds: s.eta_seconds,
        group_id: s.group_id,
        group_name: s.group_name,
    }
}

fn group_to_record(
    g: panda_core::transfer::TransferGroupSnapshot,
) -> TransferGroupRecord {
    TransferGroupRecord {
        group_id: g.group_id,
        group_name: g.group_name,
        direction: from_core_direction(g.direction),
        total_count: g.total_count,
        completed_count: g.completed_count,
        total_bytes: g.total_bytes,
        transferred_bytes: g.transferred_bytes,
        status: from_core_status(g.status),
    }
}

// ---------------------------------------------------------------------------
// FFI executor — 实际 SSH/SFTP 传输
// ---------------------------------------------------------------------------

struct FfiExecutor;

impl TransferExecutor for FfiExecutor {
    fn execute(
        &self,
        ctx: panda_core::transfer::TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        Box::pin(async move {
            let cfg = load_host(&ctx.host_id).map_err(|e| e.to_string())?;
            let creds = credentials_for(&cfg, ctx.password.clone(), ctx.passphrase.clone())
                .map_err(|e| e.to_string())?;
            let store_path = stores()
                .map_err(|e| e.to_string())?
                .core
                .known_hosts_store()
                .path()
                .to_path_buf();
            let mut known_hosts = KnownHosts::new(store_path);
            let session = SshSession::connect_shared(
                &cfg,
                creds,
                &mut known_hosts,
                UnknownHostKeyPolicy::Reject,
            )
            .await
            .map_err(|e| e.to_string())?;
            let owner_label = match ctx.direction {
                TransferDirection::Upload => "上传任务",
                TransferDirection::Download => "下载任务",
            };
            session.set_owner(owner_label, ctx.host_id.clone());
            let sftp = SftpClient::new(&session).await.map_err(|e| e.to_string())?;

            let result = match ctx.direction {
                TransferDirection::Upload => {
                    let local = PathBuf::from(&ctx.local_path);
                    sftp.upload_with_pause(
                        local.as_path(),
                        &ctx.remote_path,
                        Some(ctx.progress.clone()),
                        Some(ctx.cancel.clone()),
                        Some(ctx.paused.clone()),
                        Some(ctx.resume_notify.clone()),
                    )
                    .await
                }
                TransferDirection::Download => {
                    let local = PathBuf::from(&ctx.local_path);
                    sftp.download_with_pause(
                        &ctx.remote_path,
                        local.as_path(),
                        Some(ctx.progress.clone()),
                        Some(ctx.cancel.clone()),
                        Some(ctx.paused.clone()),
                        Some(ctx.resume_notify.clone()),
                    )
                    .await
                }
            };
            let _ = sftp.close().await;
            result.map_err(|e| e.to_string())
        })
    }
}

// ---------------------------------------------------------------------------
// Global service state
// ---------------------------------------------------------------------------

static TRANSFER_SERVICE: Mutex<Option<TransferService>> = Mutex::new(None);
/// FFI 层变更计数器；由核心 `on_change` 回调同步递增。
/// `batch_transfer` 模块也依赖此计数器。
static TRANSFER_CHANGE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn transfer_service() -> TransferService {
    let mut guard = TRANSFER_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(ref svc) = *guard {
        return svc.clone();
    }
    let svc = TransferService::with_concurrency(
        Box::new(FfiExecutor),
        TRANSFER_CONCURRENCY,
        Some(Arc::new(|| {
            TRANSFER_CHANGE_COUNTER.fetch_add(1, Ordering::Relaxed);
        })),
    );
    *guard = Some(svc.clone());
    svc
}

/// 状态变更时调用：递增 FFI 层变更计数器。
/// `batch_transfer` 模块通过 `super::notify_transfer_changed` 调用此函数。
fn notify_transfer_changed() {
    TRANSFER_CHANGE_COUNTER.fetch_add(1, Ordering::Relaxed);
}

fn total_size(local: &std::path::Path) -> u64 {
    std::fs::metadata(local).map(|m| m.len()).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// FFI exports — 薄代理至核心 TransferService
// ---------------------------------------------------------------------------

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
    let _cfg = load_host(&host_id)?;
    let size = match direction {
        TransferDirectionEnum::Upload if size == 0 => {
            total_size(PathBuf::from(&local_path).as_path())
        }
        _ => size,
    };
    let params = TransferParams {
        direction: to_core_direction(direction),
        host_id,
        local_path,
        remote_path,
        size,
        password,
        passphrase,
        group_id,
        group_name,
    };
    let id = runtime()
        .block_on(async { transfer_service().start_transfer(params) })
        .map_err(|e| PandaError::Core(e.to_string()))?;
    Ok(id)
}

#[uniffi::export]
pub fn transfer_status(task_id: String) -> Result<TransferStatusRecord, PandaError> {
    let snap = runtime()
        .block_on(async { transfer_service().transfer_status(&task_id) })
        .map_err(|e| match e {
            ref core_err
                if core_err.to_string().contains("未知任务")
                    || core_err.to_string().contains("无效任务") =>
            {
                PandaError::UnknownTransferTask(task_id)
            }
            _ => PandaError::Core(e.to_string()),
        })?;
    Ok(snapshot_to_record(snap))
}

#[uniffi::export]
pub fn transfer_list() -> Result<Vec<TransferStatusRecord>, PandaError> {
    let list = runtime().block_on(async { transfer_service().transfer_list() });
    Ok(list.into_iter().map(snapshot_to_record).collect())
}

#[uniffi::export]
pub fn transfer_groups() -> Result<Vec<TransferGroupRecord>, PandaError> {
    let groups = runtime().block_on(async { transfer_service().transfer_groups() });
    Ok(groups.into_iter().map(group_to_record).collect())
}

#[uniffi::export]
pub fn transfer_cancel(task_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().transfer_cancel(&task_id) })
        .map_err(|e| match e {
            ref core_err
                if core_err.to_string().contains("未知任务")
                    || core_err.to_string().contains("无效任务") =>
            {
                PandaError::UnknownTransferTask(task_id)
            }
            _ => PandaError::Core(e.to_string()),
        })
}

#[uniffi::export]
pub fn transfer_retry(task_id: String) -> Result<String, PandaError> {
    runtime()
        .block_on(async { transfer_service().transfer_retry(&task_id) })
        .map_err(|e| match e {
            ref core_err
                if core_err.to_string().contains("未知任务")
                    || core_err.to_string().contains("无效任务") =>
            {
                PandaError::UnknownTransferTask(task_id)
            }
            _ => PandaError::Core(e.to_string()),
        })
}

#[uniffi::export]
pub fn transfer_pause(task_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().transfer_pause(&task_id) })
        .map_err(|e| {
            let msg = e.to_string();
            if msg.contains("未知任务") || msg.contains("无效任务") {
                PandaError::UnknownTransferTask(task_id)
            } else if msg.contains("已终态") {
                PandaError::Core("task is already terminal".to_string())
            } else {
                PandaError::Core(msg)
            }
        })
}

#[uniffi::export]
pub fn transfer_resume(task_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().transfer_resume(&task_id) })
        .map_err(|e| match e {
            ref core_err
                if core_err.to_string().contains("未知任务")
                    || core_err.to_string().contains("无效任务") =>
            {
                PandaError::UnknownTransferTask(task_id)
            }
            _ => PandaError::Core(e.to_string()),
        })
}

#[uniffi::export]
pub fn transfer_group_cancel(group_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().group_cancel(&group_id) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn transfer_group_pause(group_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().group_pause(&group_id) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn transfer_group_resume(group_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().group_resume(&group_id) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn transfer_group_retry(group_id: String) -> Result<(), PandaError> {
    runtime()
        .block_on(async { transfer_service().group_retry(&group_id) })
        .map_err(|e| PandaError::Core(e.to_string()))
}

#[uniffi::export]
pub fn transfer_change_counter() -> u64 {
    TRANSFER_CHANGE_COUNTER.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// SFTP 编排：扫描→聚合→入队 一站式入口
// ---------------------------------------------------------------------------

/// 编排结果：独立传输任务 id 列表 + 批量传输任务 id 列表。
#[derive(Debug, Clone, uniffi::Record)]
pub struct OrchestrationResultRecord {
    pub transfer_ids: Vec<String>,
    pub batch_ids: Vec<String>,
}

/// 将扫描+聚合→选择任务类型→入队工作流集中为单一入口。
///
/// 调用方提供扫描结果和选中路径；核心规划后直接入队：
/// - 上传时：目录组 → 批量传输；独立文件 → 单文件传输
/// - 下载时：目录组内文件 → 共享 groupID 的独立传输；独立文件 → 单文件传输
#[uniffi::export]
pub fn orchestrate_sftp_transfers(
    selected_paths: Vec<String>,
    items: Vec<TaskItemRecord>,
    direction: TransferDirectionEnum,
    host_id: String,
    dest_dir: String,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<OrchestrationResultRecord, PandaError> {
    let _cfg = load_host(&host_id)?;

    let core_items: Vec<panda_core::TaskItem> = items
        .iter()
        .map(|r| panda_core::TaskItem {
            source: r.source.clone(),
            destination: r.destination.clone(),
            size: r.size,
            name: r.name.clone(),
            is_dir: r.is_dir,
        })
        .collect();

    let core_direction = match direction {
        TransferDirectionEnum::Upload => SftpOrchestrationDirection::Upload,
        TransferDirectionEnum::Download => SftpOrchestrationDirection::Download,
    };

    let plan = plan_sftp_orchestration(&selected_paths, &core_items, core_direction);

    let mut transfer_ids = Vec::new();
    let mut batch_ids = Vec::new();

    for planned in &plan.transfers {
        let size = match direction {
            TransferDirectionEnum::Upload if planned.size == 0 => {
                total_size(PathBuf::from(&planned.source).as_path())
            }
            _ => planned.size,
        };
        let params = TransferParams {
            direction: to_core_direction(direction),
            host_id: host_id.clone(),
            local_path: if direction == TransferDirectionEnum::Upload {
                planned.source.clone()
            } else {
                planned.destination.clone()
            },
            remote_path: if direction == TransferDirectionEnum::Upload {
                planned.destination.clone()
            } else {
                planned.source.clone()
            },
            size,
            password: password.clone(),
            passphrase: passphrase.clone(),
            group_id: planned.group_id.clone(),
            group_name: planned.group_name.clone(),
        };
        let id = runtime()
            .block_on(async { transfer_service().start_transfer(params) })
            .map_err(|e| PandaError::Core(e.to_string()))?;
        transfer_ids.push(id);
    }

    for batch in &plan.batches {
        let id = match direction {
            TransferDirectionEnum::Upload => runtime()
                .block_on(async {
                    batch_transfer::batch_service().start_upload(
                        host_id.clone(),
                        batch.sources.clone(),
                        dest_dir.clone(),
                        password.clone(),
                        passphrase.clone(),
                    )
                })
                .map_err(|e| PandaError::Core(e.to_string()))?,
            TransferDirectionEnum::Download => runtime()
                .block_on(async {
                    batch_transfer::batch_service().start_download(
                        host_id.clone(),
                        batch.sources.clone(),
                        dest_dir.clone(),
                        password.clone(),
                        passphrase.clone(),
                    )
                })
                .map_err(|e| PandaError::Core(e.to_string()))?,
        };
        batch_ids.push(id);
    }

    Ok(OrchestrationResultRecord {
        transfer_ids,
        batch_ids,
    })
}

/// 测试用：重置全局服务与计数器。
#[cfg(test)]
pub(crate) fn reset_transfer_service_for_test() {
    let mut guard = TRANSFER_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *guard = None;
    TRANSFER_CHANGE_COUNTER.store(0, Ordering::Relaxed);

    let dir = tempfile::tempdir().unwrap();
    let dir_path = dir.path().to_path_buf();
    std::mem::forget(dir);
    crate::init_store(dir_path.to_string_lossy().into_owned()).unwrap();
    let mut record = crate::HostConfigRecord {
        id: "test-host".into(),
        name: "测试主机".into(),
        host: "127.0.0.1".into(),
        port: 22,
        username: "test".into(),
        auth: crate::AuthMethodEnum::Password { password_ref: None },
        notes: None,
        group_id: None,
    };
    record.id = "test-host".into();
    crate::save_host(record).unwrap();

    let mut refused = crate::HostConfigRecord {
        id: "refused-host".into(),
        name: "拒绝连接".into(),
        host: "127.0.0.1".into(),
        port: 1,
        username: "deploy".into(),
        auth: crate::AuthMethodEnum::Password {
            password_ref: Some("pw".into()),
        },
        notes: None,
        group_id: None,
    };
    refused.id = "refused-host".into();
    crate::save_host(refused).unwrap();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "tests/ffi_transfers_tests.rs"]
mod tests;
