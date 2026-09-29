//! 删除域 FFI 导出：本地/远端删除任务、快照、取消。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use panda_core::delete_tasks::LocalDeleteFileSystem;
use panda_core::task_summary::{WorkKind, WorkStatus};
use panda_core::DeleteService;

use crate::ffi_runtime::runtime;
use crate::ffi_store::stores;
use crate::PandaError;

// ---------------------------------------------------------------------------
// Exported types (UniFFI)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeleteKindEnum {
    Local,
    Remote,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeleteStatusEnum {
    Preparing,
    Scanning,
    Queued,
    Running,
    Paused,
    WaitingForDecision,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
    Skipped,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DeleteFailureRecord {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DeleteTaskSnapshotRecord {
    pub task_id: String,
    pub kind: DeleteKindEnum,
    pub status: DeleteStatusEnum,
    pub source: String,
    pub processed: u64,
    pub total: Option<u64>,
    pub discovered: u64,
    pub succeeded: u64,
    pub current_path: Option<String>,
    pub errors: Vec<DeleteFailureRecord>,
}

fn to_snapshot_record(
    snap: panda_core::delete_service::DeleteServiceSnapshot,
) -> DeleteTaskSnapshotRecord {
    DeleteTaskSnapshotRecord {
        task_id: snap.task_id,
        kind: match snap.snapshot.kind {
            WorkKind::LocalDelete => DeleteKindEnum::Local,
            WorkKind::RemoteDelete => DeleteKindEnum::Remote,
            _ => unreachable!(),
        },
        status: match snap.snapshot.status {
            WorkStatus::Preparing => DeleteStatusEnum::Preparing,
            WorkStatus::Scanning => DeleteStatusEnum::Scanning,
            WorkStatus::Queued => DeleteStatusEnum::Queued,
            WorkStatus::Running => DeleteStatusEnum::Running,
            WorkStatus::Paused => DeleteStatusEnum::Paused,
            WorkStatus::WaitingForDecision => DeleteStatusEnum::WaitingForDecision,
            WorkStatus::Cancelling => DeleteStatusEnum::Cancelling,
            WorkStatus::Completed => DeleteStatusEnum::Completed,
            WorkStatus::Failed => DeleteStatusEnum::Failed,
            WorkStatus::Cancelled => DeleteStatusEnum::Cancelled,
            WorkStatus::Skipped => DeleteStatusEnum::Skipped,
        },
        source: snap.snapshot.source,
        processed: snap.snapshot.processed,
        total: snap.snapshot.total,
        discovered: snap.snapshot.discovered,
        succeeded: snap.snapshot.succeeded,
        current_path: snap.snapshot.current_path.clone(),
        errors: snap
            .snapshot
            .errors
            .iter()
            .map(|f| DeleteFailureRecord {
                path: f.path.clone(),
                message: f.message.clone(),
            })
            .collect(),
    }
}

// ---------------------------------------------------------------------------
// Global DeleteService
// ---------------------------------------------------------------------------

static DELETE_SERVICE: Mutex<Option<DeleteService>> = Mutex::new(None);
static DELETE_CHANGE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn delete_service() -> DeleteService {
    let mut guard = DELETE_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(ref svc) = *guard {
        return svc.clone();
    }
    let svc = DeleteService::new(Some(Arc::new(|| {
        DELETE_CHANGE_COUNTER.fetch_add(1, Ordering::Relaxed);
    })));
    *guard = Some(svc.clone());
    svc
}

/// 重置删除服务（仅 XCTest 用）。清空全局单例 DeleteService 和变更计数器。
/// 不能加 `#[cfg(test)]` 因为 uniffi::export 需要在 release 构建时存在符号。
#[uniffi::export]
pub fn reset_delete_service_for_test() {
    let mut guard = DELETE_SERVICE
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *guard = None;
    DELETE_CHANGE_COUNTER.store(0, Ordering::Relaxed);
}

// ---------------------------------------------------------------------------
// FFI exports
// ---------------------------------------------------------------------------

/// 启动本地文件/目录删除任务。
#[uniffi::export]
pub fn start_local_delete(targets: Vec<String>) -> Result<String, PandaError> {
    let svc = delete_service();
    runtime()
        .block_on(async { svc.start_delete(WorkKind::LocalDelete, targets, LocalDeleteFileSystem) })
        .map_err(|e| PandaError::Core(e))
}

/// 启动远端 SFTP 删除任务。
#[uniffi::export]
pub fn start_remote_delete(
    handle: u64,
    targets: Vec<String>,
) -> Result<String, PandaError> {
    let core = &stores()?.core;
    runtime().block_on(async {
        let fs = core.create_sftp_delete_fs(handle).await?;
        let svc = delete_service();
        svc.start_delete(WorkKind::RemoteDelete, targets, fs)
            .map_err(|e| PandaError::Core(e))
    })
}

/// 查询删除任务快照。
#[uniffi::export]
pub fn delete_task_status(task_id: String) -> Result<DeleteTaskSnapshotRecord, PandaError> {
    let svc = delete_service();
    svc.status(&task_id)
        .map(to_snapshot_record)
        .map_err(|e| PandaError::Core(e))
}

/// 列出所有删除任务。
#[uniffi::export]
pub fn delete_task_list() -> Vec<DeleteTaskSnapshotRecord> {
    let svc = delete_service();
    svc.list().into_iter().map(to_snapshot_record).collect()
}

/// 取消删除任务。
#[uniffi::export]
pub fn delete_task_cancel(task_id: String) -> Result<(), PandaError> {
    let svc = delete_service();
    svc.cancel(&task_id).map_err(|e| PandaError::Core(e))
}

/// 删除服务变更计数器，用于 UI 增量刷新。
#[uniffi::export]
pub fn delete_change_counter() -> u64 {
    DELETE_CHANGE_COUNTER.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::global_test_lock;

    fn setup() {
        reset_delete_service_for_test();
    }

    #[test]
    fn local_delete_single_file_completes() {
        let _g = global_test_lock();
        setup();
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, "hello").unwrap();

        let id = start_local_delete(vec![file_path.to_string_lossy().into()]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));

        let snap = delete_task_status(id).unwrap();
        assert_eq!(snap.status, DeleteStatusEnum::Completed);
        assert_eq!(snap.succeeded, 1);
        assert!(snap.errors.is_empty());
        assert!(!file_path.exists());
    }

    #[test]
    fn local_delete_directory_with_children() {
        let _g = global_test_lock();
        setup();
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("subdir");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join("a.txt"), "a").unwrap();
        std::fs::write(sub.join("b.txt"), "b").unwrap();

        let id = start_local_delete(vec![sub.to_string_lossy().into()]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));

        let snap = delete_task_status(id).unwrap();
        assert_eq!(snap.status, DeleteStatusEnum::Completed);
        assert_eq!(snap.succeeded, 3);
        assert!(snap.errors.is_empty());
    }

    #[test]
    fn local_delete_nonexistent_file_reports_error() {
        let _g = global_test_lock();
        setup();
        let id =
            start_local_delete(vec!["/nonexistent/path/file.txt".into()]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));

        let snap = delete_task_status(id).unwrap();
        assert_eq!(snap.status, DeleteStatusEnum::Failed);
        assert!(!snap.errors.is_empty());
    }

    #[test]
    fn delete_task_list_returns_all_tasks() {
        let _g = global_test_lock();
        setup();
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "a").unwrap();
        std::fs::write(&f2, "b").unwrap();

        start_local_delete(vec![f1.to_string_lossy().into()]).unwrap();
        start_local_delete(vec![f2.to_string_lossy().into()]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));

        let list = delete_task_list();
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn delete_task_cancel_unknown_returns_error() {
        let _g = global_test_lock();
        setup();
        let result = delete_task_cancel("nonexistent-id".into());
        assert!(result.is_err());
    }

    #[test]
    fn delete_task_status_unknown_returns_error() {
        let _g = global_test_lock();
        setup();
        let result = delete_task_status("nonexistent-id".into());
        assert!(result.is_err());
    }

    #[test]
    fn delete_change_counter_increments() {
        let _g = global_test_lock();
        setup();
        let before = delete_change_counter();
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("counter.txt");
        std::fs::write(&file, "data").unwrap();
        start_local_delete(vec![file.to_string_lossy().into()]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        let after = delete_change_counter();
        assert!(after > before);
    }

    #[test]
    fn local_delete_empty_targets_returns_error() {
        let _g = global_test_lock();
        setup();
        let result = start_local_delete(vec![]);
        assert!(result.is_err());
    }

    #[test]
    fn to_snapshot_record_maps_all_statuses_and_kinds() {
        use panda_core::delete_service::DeleteServiceSnapshot;
        use panda_core::task_summary::{WorkKind, WorkSnapshot, WorkStatus};

        let all_statuses = [
            (WorkStatus::Preparing, DeleteStatusEnum::Preparing),
            (WorkStatus::Scanning, DeleteStatusEnum::Scanning),
            (WorkStatus::Queued, DeleteStatusEnum::Queued),
            (WorkStatus::Running, DeleteStatusEnum::Running),
            (WorkStatus::Paused, DeleteStatusEnum::Paused),
            (
                WorkStatus::WaitingForDecision,
                DeleteStatusEnum::WaitingForDecision,
            ),
            (WorkStatus::Cancelling, DeleteStatusEnum::Cancelling),
            (WorkStatus::Completed, DeleteStatusEnum::Completed),
            (WorkStatus::Failed, DeleteStatusEnum::Failed),
            (WorkStatus::Cancelled, DeleteStatusEnum::Cancelled),
            (WorkStatus::Skipped, DeleteStatusEnum::Skipped),
        ];

        for (ws, expected) in all_statuses {
            let snap = WorkSnapshot::new("t1".into(), WorkKind::LocalDelete, ws, "/a".into());
            let dss = DeleteServiceSnapshot {
                task_id: "t1".into(),
                snapshot: snap,
            };
            let rec = to_snapshot_record(dss);
            assert_eq!(rec.status, expected, "status mismatch for {ws:?}");
            assert_eq!(rec.kind, DeleteKindEnum::Local);
        }

        let snap = WorkSnapshot::new(
            "t2".into(),
            WorkKind::RemoteDelete,
            WorkStatus::Running,
            "/b".into(),
        );
        let dss = DeleteServiceSnapshot {
            task_id: "t2".into(),
            snapshot: snap,
        };
        let rec = to_snapshot_record(dss);
        assert_eq!(rec.kind, DeleteKindEnum::Remote);
        assert_eq!(rec.status, DeleteStatusEnum::Running);
    }

    #[test]
    fn local_delete_cancel_before_completion() {
        let _g = global_test_lock();
        setup();
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("cancel_dir");
        std::fs::create_dir_all(&sub).unwrap();
        for i in 0..10 {
            std::fs::write(sub.join(format!("file_{i}.txt")), "data").unwrap();
        }

        let id = start_local_delete(vec![sub.to_string_lossy().into()]).unwrap();
        let _ = delete_task_cancel(id.clone());
        std::thread::sleep(std::time::Duration::from_millis(100));

        let snap = delete_task_status(id).unwrap();
        assert!(
            snap.status == DeleteStatusEnum::Cancelled
                || snap.status == DeleteStatusEnum::Completed
        );
    }
}
