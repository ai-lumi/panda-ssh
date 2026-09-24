use super::*;
use std::sync::atomic::AtomicUsize;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Default)]
struct ExecutionCounts {
    active: AtomicUsize,
    peak: AtomicUsize,
}

struct ActiveExecution(Arc<ExecutionCounts>);
impl ActiveExecution {
    fn new(counts: Arc<ExecutionCounts>) -> Self {
        let current = counts.active.fetch_add(1, Ordering::SeqCst) + 1;
        counts.peak.fetch_max(current, Ordering::SeqCst);
        Self(counts)
    }
}
impl Drop for ActiveExecution {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::SeqCst);
    }
}

struct ConflictCall {
    #[allow(dead_code)]
    task_id: String,
    release: oneshot::Sender<Result<Option<ConflictInfo>, String>>,
}

struct FileCall {
    path: String,
    release: oneshot::Sender<Result<(), String>>,
}

struct ConflictControlledExecutor {
    conflict_calls: mpsc::UnboundedSender<ConflictCall>,
    file_calls: mpsc::UnboundedSender<FileCall>,
    counts: Arc<ExecutionCounts>,
}

impl TransferExecutor for ConflictControlledExecutor {
    fn execute(
        &self,
        ctx: TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        let file_calls = self.file_calls.clone();
        let _active = ActiveExecution::new(self.counts.clone());
        let path = match ctx.direction {
            TransferDirection::Upload => ctx.remote_path.clone(),
            TransferDirection::Download => ctx.local_path.clone(),
        };
        Box::pin(async move {
            let _active = _active;
            let (release, receiver) = oneshot::channel();
            file_calls
                .send(FileCall {
                    path,
                    release,
                })
                .unwrap();
            receiver
                .await
                .unwrap_or_else(|_| Err("测试执行已释放".into()))
        })
    }

    fn check_conflict(
        &self,
        ctx: &TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<Option<ConflictInfo>, String>> + Send>> {
        let conflict_calls = self.conflict_calls.clone();
        let task_id = ctx.local_path.clone();
        Box::pin(async move {
            let (release, receiver) = oneshot::channel();
            conflict_calls
                .send(ConflictCall {
                    task_id,
                    release,
                })
                .unwrap();
            receiver
                .await
                .unwrap_or_else(|_| Ok(None))
        })
    }
}

fn conflict_controlled(
    concurrency: usize,
) -> (
    TransferService,
    mpsc::UnboundedReceiver<ConflictCall>,
    mpsc::UnboundedReceiver<FileCall>,
    Arc<ExecutionCounts>,
) {
    let (conflict_tx, conflict_rx) = mpsc::unbounded_channel();
    let (file_tx, file_rx) = mpsc::unbounded_channel();
    let counts = Arc::new(ExecutionCounts::default());
    let service = TransferService::with_concurrency_and_conflict_timeout(
        Box::new(ConflictControlledExecutor {
            conflict_calls: conflict_tx,
            file_calls: file_tx,
            counts: counts.clone(),
        }),
        concurrency,
        None,
        1,
    );
    (service, conflict_rx, file_rx, counts)
}

async fn next_conflict(calls: &mut mpsc::UnboundedReceiver<ConflictCall>) -> ConflictCall {
    tokio::time::timeout(Duration::from_secs(2), calls.recv())
        .await
        .expect("冲突检查必须被调度")
        .unwrap()
}

async fn next_file(calls: &mut mpsc::UnboundedReceiver<FileCall>) -> FileCall {
    tokio::time::timeout(Duration::from_secs(2), calls.recv())
        .await
        .expect("文件执行必须被调度")
        .unwrap()
}

async fn until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("状态未到达预期");
}

fn upload_params_with_id(id: &str, size: u64) -> TransferParams {
    TransferParams {
        direction: TransferDirection::Upload,
        host_id: "host-1".into(),
        local_path: format!("/local/{id}"),
        remote_path: format!("/remote/{id}"),
        size,
        password: None,
        passphrase: None,
        group_id: None,
        group_name: None,
    }
}

#[tokio::test]
async fn no_conflict_proceeds_to_completion() {
    let (service, mut conflict_calls, mut file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("noc", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    conflict.release.send(Ok(None)).unwrap();
    let file = next_file(&mut file_calls).await;
    assert_eq!(file.path, "/remote/noc");
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn conflict_overwrite_proceeds_to_completion() {
    let (service, mut conflict_calls, mut file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("cow", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    let snap = service.transfer_status(&id).unwrap();
    assert!(snap.conflict.is_some());
    assert_eq!(snap.status, TransferStatus::Running);
    service.resolve_conflict(&id, true).unwrap();
    let file = next_file(&mut file_calls).await;
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn conflict_skip_sets_skipped_status() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("skip", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    service.resolve_conflict(&id, false).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Skipped).await;
    assert!(file_calls.is_empty());
    let snap = service.transfer_status(&id).unwrap();
    assert_eq!(snap.transferred, 0);
}

#[tokio::test]
async fn conflict_check_error_sets_failed() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("err", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    conflict.release.send(Err("Permission denied".into())).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Failed).await;
    let snap = service.transfer_status(&id).unwrap();
    assert!(snap.error.is_some());
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn conflict_timeout_defaults_to_skip() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("timeout", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Skipped).await;
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn conflict_cancel_sets_cancelled() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("cancel", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    service.transfer_cancel(&id).unwrap();
    until(|| {
        matches!(
            service.transfer_status(&id).unwrap().status,
            TransferStatus::Cancelled | TransferStatus::Skipped
        )
    })
    .await;
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn target_is_directory_error_not_silent_overwrite() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("isdir", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    conflict
        .release
        .send(Err("目标为目录: /remote/isdir".into()))
        .unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Failed).await;
    let snap = service.transfer_status(&id).unwrap();
    assert!(snap.error.as_ref().unwrap().contains("目标为目录"));
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn skipped_is_terminal_and_distinguishable() {
    assert!(TransferStatus::Skipped.is_terminal());
    assert_ne!(TransferStatus::Skipped, TransferStatus::Completed);
    assert_ne!(TransferStatus::Skipped, TransferStatus::Failed);
    assert_ne!(TransferStatus::Skipped, TransferStatus::Cancelled);
}

#[tokio::test]
async fn late_conflict_decision_is_ignored() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let id = service.start_transfer(upload_params_with_id("late", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    service.resolve_conflict(&id, false).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Skipped).await;
    assert!(service.resolve_conflict(&id, true).is_err() || !service.resolve_conflict(&id, true).unwrap());
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn pause_during_conflict_wait_defers_until_resume() {
    let (service, mut conflict_calls, mut file_calls, _) = conflict_controlled(1);
    let id = service.start_transfer(upload_params_with_id("pdc", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;

    service.transfer_pause(&id).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Paused).await;

    service.resolve_conflict(&id, true).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        service.transfer_status(&id).unwrap().status,
        TransferStatus::Paused,
        "收到覆盖决策后暂停中不得开始写入"
    );
    assert!(file_calls.is_empty());

    service.transfer_resume(&id).unwrap();
    let file = next_file(&mut file_calls).await;
    assert_eq!(file.path, "/remote/pdc");
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn cancel_during_paused_conflict_wait() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(1);
    let id = service.start_transfer(upload_params_with_id("cpc", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;

    service.transfer_pause(&id).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Paused).await;

    service.transfer_cancel(&id).unwrap();
    until(|| {
        matches!(
            service.transfer_status(&id).unwrap().status,
            TransferStatus::Cancelled | TransferStatus::Skipped
        )
    })
    .await;
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn retry_after_skip_produces_new_conflict_check() {
    let (service, mut conflict_calls, mut file_calls, _) = conflict_controlled(1);
    let id = service.start_transfer(upload_params_with_id("rsk", 100)).unwrap();

    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;
    service.resolve_conflict(&id, false).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Skipped).await;

    let retried_id = service.transfer_retry(&id).unwrap();
    assert_eq!(retried_id, id, "重试必须保持同一任务 ID");

    let conflict2 = next_conflict(&mut conflict_calls).await;
    conflict2.release.send(Ok(None)).unwrap();
    let file = next_file(&mut file_calls).await;
    assert_eq!(file.path, "/remote/rsk");
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn wrong_task_id_resolve_returns_error() {
    let (service, mut conflict_calls, _, _) = conflict_controlled(1);
    let id = service.start_transfer(upload_params_with_id("wti", 100)).unwrap();
    let conflict = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 100,
        source_mtime: Some(1000),
        target_size: 50,
        target_mtime: Some(900),
    };
    conflict.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id).unwrap().conflict.is_some()).await;

    assert!(service.resolve_conflict("not-a-uuid", true).is_err());
    let foreign = "00000000-0000-0000-0000-000000000000";
    assert!(service.resolve_conflict(foreign, true).is_err());
    assert_eq!(service.resolve_conflict(&id, true).unwrap(), true);
}

#[tokio::test]
async fn all_slots_waiting_timeout_independently() {
    let (service, mut conflict_calls, file_calls, _) = conflict_controlled(3);
    let mut ids = Vec::new();
    for i in 0..3 {
        let id = service
            .start_transfer(upload_params_with_id(&format!("multi{i}"), 100))
            .unwrap();
        let conflict = next_conflict(&mut conflict_calls).await;
        let info = ConflictInfo {
            source_size: 100,
            source_mtime: Some(1000),
            target_size: 50,
            target_mtime: Some(900),
        };
        conflict.release.send(Ok(Some(info))).unwrap();
        ids.push(id);
    }
    for id in &ids {
        until(|| service.transfer_status(id).unwrap().conflict.is_some()).await;
    }
    for id in &ids {
        until(|| service.transfer_status(id).unwrap().status == TransferStatus::Skipped).await;
    }
    assert!(file_calls.is_empty());
}

#[tokio::test]
async fn same_target_serialized() {
    let (service, mut conflict_calls, mut file_calls, counts) = conflict_controlled(3);
    let id_a = service
        .start_transfer(upload_params_with_id("same", 100))
        .unwrap();
    let id_b = service
        .start_transfer(upload_params_with_id("same", 200))
        .unwrap();

    let ca = next_conflict(&mut conflict_calls).await;
    ca.release.send(Ok(None)).unwrap();
    let fa = next_file(&mut file_calls).await;
    assert_eq!(fa.path, "/remote/same");
    assert_eq!(counts.peak.load(Ordering::SeqCst), 1, "同目标不得并行");

    fa.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_a).unwrap().status == TransferStatus::Completed).await;

    let cb = next_conflict(&mut conflict_calls).await;
    cb.release.send(Ok(None)).unwrap();
    let fb = next_file(&mut file_calls).await;
    assert_eq!(fb.path, "/remote/same");
    fb.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_b).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn different_targets_concurrent() {
    let (service, mut conflict_calls, mut file_calls, counts) = conflict_controlled(3);
    let id_a = service
        .start_transfer(upload_params_with_id("alpha", 100))
        .unwrap();
    let id_b = service
        .start_transfer(upload_params_with_id("beta", 100))
        .unwrap();

    let ca = next_conflict(&mut conflict_calls).await;
    ca.release.send(Ok(None)).unwrap();
    let cb = next_conflict(&mut conflict_calls).await;
    cb.release.send(Ok(None)).unwrap();

    let fa = next_file(&mut file_calls).await;
    let fb = next_file(&mut file_calls).await;
    assert_eq!(counts.peak.load(Ordering::SeqCst), 2, "不同目标必须并行");

    fa.release.send(Ok(())).unwrap();
    fb.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_a).unwrap().status == TransferStatus::Completed).await;
    until(|| service.transfer_status(&id_b).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn target_released_after_failure_rechecks_conflict() {
    let (service, mut conflict_calls, mut file_calls, _) = conflict_controlled(2);
    let id_a = service
        .start_transfer(upload_params_with_id("fail", 100))
        .unwrap();
    let id_b = service
        .start_transfer(upload_params_with_id("fail", 200))
        .unwrap();

    let ca = next_conflict(&mut conflict_calls).await;
    ca.release.send(Ok(None)).unwrap();
    let fa = next_file(&mut file_calls).await;
    fa.release.send(Err("写入失败".into())).unwrap();
    until(|| service.transfer_status(&id_a).unwrap().status == TransferStatus::Failed).await;

    let cb = next_conflict(&mut conflict_calls).await;
    let info = ConflictInfo {
        source_size: 200,
        source_mtime: Some(2000),
        target_size: 100,
        target_mtime: Some(1500),
    };
    cb.release.send(Ok(Some(info))).unwrap();
    until(|| service.transfer_status(&id_b).unwrap().conflict.is_some()).await;
    service.resolve_conflict(&id_b, true).unwrap();
    let fb = next_file(&mut file_calls).await;
    fb.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_b).unwrap().status == TransferStatus::Completed).await;
}

#[tokio::test]
async fn target_wait_does_not_consume_slot() {
    let (service, mut conflict_calls, mut file_calls, counts) = conflict_controlled(2);
    let id_a = service
        .start_transfer(upload_params_with_id("x", 100))
        .unwrap();
    let id_b = service
        .start_transfer(upload_params_with_id("x", 100))
        .unwrap();
    let id_c = service
        .start_transfer(upload_params_with_id("y", 100))
        .unwrap();

    let ca = next_conflict(&mut conflict_calls).await;
    ca.release.send(Ok(None)).unwrap();
    let fa = next_file(&mut file_calls).await;
    assert_eq!(fa.path, "/remote/x");

    let cc = next_conflict(&mut conflict_calls).await;
    cc.release.send(Ok(None)).unwrap();
    let fc = next_file(&mut file_calls).await;
    assert_eq!(fc.path, "/remote/y");

    assert_eq!(
        counts.peak.load(Ordering::SeqCst),
        2,
        "等待同目标的 B 不占额度，C 到不同目标可并行"
    );

    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        service.transfer_status(&id_b).unwrap().status != TransferStatus::Completed,
        "B 必须等待 A 完成"
    );

    fa.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_a).unwrap().status == TransferStatus::Completed).await;

    let cb = next_conflict(&mut conflict_calls).await;
    cb.release.send(Ok(None)).unwrap();
    let fb = next_file(&mut file_calls).await;
    assert_eq!(fb.path, "/remote/x");
    fb.release.send(Ok(())).unwrap();
    fc.release.send(Ok(())).unwrap();
    until(|| service.transfer_status(&id_b).unwrap().status == TransferStatus::Completed).await;
    until(|| service.transfer_status(&id_c).unwrap().status == TransferStatus::Completed).await;
}
