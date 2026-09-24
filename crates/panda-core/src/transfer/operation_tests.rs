use super::*;
use crate::sftp_orchestration::{PlannedGroup, PlannedTransfer, SftpOrchestrationPlan};
use crate::task_aggregation::TaskItem;
use std::sync::atomic::AtomicUsize;
use tokio::sync::oneshot;

fn params(direction: TransferDirection) -> TransferOperationParams {
    TransferOperationParams {
        direction,
        host_id: "fake-host".into(),
        sources: vec!["/source/中文 空目录".into()],
        destination_dir: "/destination".into(),
        password: Some("test-only-password-marker".into()),
        passphrase: Some("test-only-passphrase-marker".into()),
    }
}

fn plan(count: usize, grouped: bool) -> SftpOrchestrationPlan {
    SftpOrchestrationPlan {
        transfers: (0..count)
            .map(|i| PlannedTransfer {
                source: format!("/source/中文 空目录/{i}"),
                destination: format!("/destination/中文 空目录/{i}"),
                size: 0,
                name: i.to_string(),
                group_id: grouped.then(|| "group".into()),
                group_name: grouped.then(|| "中文 空目录".into()),
            })
            .collect(),
        groups: if grouped {
            vec![PlannedGroup {
                group_id: "group".into(),
                name: "中文 空目录".into(),
                source_root: "/source/中文 空目录".into(),
                destination_root: "/destination/中文 空目录".into(),
                directories: vec![TaskItem {
                    source: "/source/中文 空目录".into(),
                    destination: "/destination/中文 空目录".into(),
                    size: 0,
                    name: "中文 空目录".into(),
                    is_dir: true,
                }],
            }]
        } else {
            vec![]
        },
        batches: vec![],
    }
}

struct CountingExecutor(Arc<AtomicUsize>);
impl TransferExecutor for CountingExecutor {
    fn execute(
        &self,
        ctx: TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move {
            assert_eq!(ctx.password.as_deref(), Some("test-only-password-marker"));
            assert_eq!(
                ctx.passphrase.as_deref(),
                Some("test-only-passphrase-marker")
            );
            Ok(())
        })
    }

    fn open_directory(
        &self,
        _: DirectoryContext,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn DirectoryWriter>, String>> + Send>> {
        Box::pin(std::future::pending())
    }
}

fn service() -> (TransferService, Arc<AtomicUsize>) {
    let calls = Arc::new(AtomicUsize::new(0));
    (
        TransferService::new(Box::new(CountingExecutor(calls.clone()))),
        calls,
    )
}

async fn until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("状态未在期限内到达");
}

struct Dropped(Option<oneshot::Sender<()>>);
impl Drop for Dropped {
    fn drop(&mut self) {
        if let Some(tx) = self.0.take() {
            let _ = tx.send(());
        }
    }
}

#[tokio::test]
async fn operation_visible_during_scan_and_cancel_drops_future_without_execution() {
    for direction in [TransferDirection::Upload, TransferDirection::Download] {
        let (service, calls) = service();
        let (entered_tx, entered_rx) = oneshot::channel();
        let (drop_tx, drop_rx) = oneshot::channel();
        let (release_tx, release_rx) = oneshot::channel();
        let id = service
            .start_operation(params(direction), move |_| async move {
                let _guard = Dropped(Some(drop_tx));
                entered_tx.send(()).unwrap();
                let _ = release_rx.await;
                Ok(plan(4, true))
            })
            .expect("启动必须立即登记操作")
            .unwrap();
        let initial = service.registry_snapshot();
        assert_eq!(initial.operations[0].id, id);
        assert_eq!(
            initial.operations[0].status,
            TransferOperationStatus::Scanning
        );
        assert_eq!(initial.unfinished_summary().total, 1);
        assert!(initial.transfers.is_empty() && initial.groups.is_empty());
        entered_rx.await.unwrap();
        service.cancel_operation(&id).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), drop_rx)
            .await
            .unwrap()
            .unwrap();
        assert!(release_tx.send(()).is_err());
        let terminal = service.operation_status(&id).unwrap();
        assert_eq!(terminal.status, TransferOperationStatus::Cancelled);
        assert_eq!(terminal.direction, direction);
        assert_eq!(terminal.sources, params(direction).sources);
        assert!(terminal.error.is_some());
        assert!(service.registry_snapshot().revision > initial.revision);
        assert_eq!(service.registry_snapshot().unfinished_summary().total, 0);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        service.cancel_operation(&id).unwrap();
        assert!(service.registry_snapshot().transfers.is_empty());
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn operation_handoff_is_atomic_deduplicated_and_groups_gate_files() {
    for direction in [TransferDirection::Upload, TransferDirection::Download] {
        for count in [0, 1000] {
            let (service, calls) = service();
            let (tx, rx) = oneshot::channel();
            let id = service
                .start_operation(params(direction), move |_| async move {
                    rx.await.unwrap();
                    Ok(plan(count, true))
                })
                .expect("必须接受扫描")
                .unwrap();
            let before = service.registry_snapshot().revision;
            tx.send(()).unwrap();
            until(|| {
                let snapshot = service.registry_snapshot();
                assert_eq!(snapshot.unfinished_summary().total, 1);
                let op = &snapshot.operations[0];
                if op.status == TransferOperationStatus::Scanning {
                    assert!(snapshot.transfers.is_empty() && snapshot.groups.is_empty());
                    false
                } else {
                    assert_eq!(op.status, TransferOperationStatus::HandedOff);
                    assert_eq!(snapshot.transfers.len(), count);
                    assert_eq!(op.task_ids.len(), count);
                    assert_eq!(op.group_ids, vec!["group"]);
                    assert_eq!(snapshot.groups.len(), 1);
                    assert!(matches!(snapshot.groups[0].status, TransferStatus::Queued | TransferStatus::Running));
                    assert!(snapshot
                        .transfers
                        .iter()
                        .all(|t| t.status == TransferStatus::Queued));
                    assert!(snapshot.revision > before);
                    let debug = format!("{snapshot:?}");
                    assert!(!debug.contains("test-only-password-marker"));
                    assert!(!debug.contains("test-only-passphrase-marker"));
                    true
                }
            })
            .await;
            assert_eq!(calls.load(Ordering::SeqCst), 0);
            assert_eq!(service.operation_status(&id).unwrap().id, id);
            service.cancel_operation(&id).unwrap();
            assert_eq!(service.registry_snapshot().unfinished_summary().total, 0);
        }
    }
}

#[tokio::test]
async fn operation_scan_failure_is_pathful_and_never_partially_enqueues() {
    let (service, calls) = service();
    let id = service
        .start_operation(params(TransferDirection::Upload), |_| async {
            let _partial_plan = plan(3, true);
            Err(Error::Other("/source/中文 空目录/blocked: 权限不足".into()))
        })
        .expect("扫描失败应在快照而非启动时报告")
        .unwrap();
    until(|| service.operation_status(&id).unwrap().status == TransferOperationStatus::Failed)
        .await;
    let snapshot = service.registry_snapshot();
    assert!(snapshot.operations[0]
        .error
        .as_ref()
        .unwrap()
        .contains("blocked"));
    assert_eq!(
        snapshot.operations[0].sources,
        params(TransferDirection::Upload).sources
    );
    assert!(snapshot.transfers.is_empty() && snapshot.groups.is_empty());
    assert_eq!(snapshot.unfinished_summary().total, 0);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn operation_shutdown_closes_registration_and_prevents_late_handoff() {
    let (service, calls) = service();
    let (tx, rx) = oneshot::channel();
    let id = service
        .start_operation(params(TransferDirection::Upload), |_| async move {
            let _ = rx.await;
            Ok(plan(4, true))
        })
        .expect("应接受初次操作")
        .unwrap();
    service.shutdown();
    let _ = tx.send(());
    tokio::task::yield_now().await;
    let snapshot = service.registry_snapshot();
    assert!(!snapshot.accepting);
    assert_eq!(
        snapshot.operations[0].status,
        TransferOperationStatus::Cancelled
    );
    assert!(snapshot.transfers.is_empty() && snapshot.groups.is_empty());
    assert_eq!(service.operation_status(&id).unwrap().id, id);
    assert!(service
        .start_operation(params(TransferDirection::Upload), |_| async {
            Ok(plan(1, false))
        })
        .is_err());
    assert!(service
        .start_transfer(TransferParams {
            direction: TransferDirection::Upload,
            host_id: "fake-host".into(),
            local_path: "/source/file".into(),
            remote_path: "/destination/file".into(),
            size: 1,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        })
        .is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    service.shutdown();
}

#[tokio::test]
async fn operation_empty_selection_is_no_work_and_unknown_ids_are_errors() {
    let (service, _) = service();
    let mut input = params(TransferDirection::Upload);
    input.sources.clear();
    let result = service.start_operation(input, |_| async { panic!("空选择不得扫描") });
    assert!(matches!(result, Ok(None)), "空选择应明确无工作");
    assert!(service.registry_snapshot().operations.is_empty());
    for id in ["invalid".to_string(), Uuid::new_v4().to_string()] {
        assert!(service.operation_status(&id).is_err());
        assert!(service.cancel_operation(&id).is_err());
    }
}

#[tokio::test]
async fn operation_standalone_handoff_preserves_credentials_and_direction() {
    for direction in [TransferDirection::Upload, TransferDirection::Download] {
        let (service, calls) = service();
        let id = service
            .start_operation(params(direction), |_| async { Ok(plan(2, false)) })
            .expect("独立文件应可启动")
            .unwrap();
        until(|| {
            service.registry_snapshot().transfers.len() == 2
                && service
                    .registry_snapshot()
                    .transfers
                    .iter()
                    .all(|t| t.status == TransferStatus::Completed)
        })
        .await;
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let snapshot = service.registry_snapshot();
        assert_eq!(snapshot.unfinished_summary().total, 0);
        for t in &snapshot.transfers {
            assert_eq!(t.direction, direction);
            assert_eq!(t.host_id, "fake-host");
            assert!(t
                .local_path
                .starts_with(if direction == TransferDirection::Upload {
                    "/source"
                } else {
                    "/destination"
                }));
        }
        assert_eq!(service.operation_status(&id).unwrap().task_ids.len(), 2);
    }
}

#[tokio::test]
async fn operation_shutdown_drops_running_executor_and_rejects_retry() {
    struct HoldingExecutor(Arc<Mutex<Option<oneshot::Sender<()>>>>);
    impl TransferExecutor for HoldingExecutor {
        fn execute(
            &self,
            _: TransferContext,
        ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
            let guard = Dropped(self.0.lock().unwrap().take());
            Box::pin(async move {
                let _guard = guard;
                std::future::pending().await
            })
        }
    }
    let (tx, rx) = oneshot::channel();
    let marker = Arc::new(Mutex::new(Some(tx)));
    let service = TransferService::new(Box::new(HoldingExecutor(marker.clone())));
    let id = service
        .start_operation(params(TransferDirection::Upload), |_| async {
            Ok(plan(1, false))
        })
        .unwrap()
        .unwrap();
    until(|| marker.lock().unwrap().is_none()).await;
    let task_id = service.operation_status(&id).unwrap().task_ids[0].clone();
    service.shutdown();
    tokio::time::timeout(std::time::Duration::from_secs(2), rx)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        service.transfer_status(&task_id).unwrap().status,
        TransferStatus::Cancelled
    );
    assert!(
        service.transfer_retry(&task_id).is_err(),
        "停机后禁止重新登记执行"
    );
}

#[tokio::test]
async fn operation_change_callbacks_can_read_atomic_snapshot() {
    let owner: Arc<Mutex<Option<std::sync::Weak<ServiceInner>>>> = Arc::new(Mutex::new(None));
    let callback_owner = owner.clone();
    let snapshots = Arc::new(Mutex::new(Vec::new()));
    let seen = snapshots.clone();
    let service = TransferService::with_concurrency(
        Box::new(CountingExecutor(Arc::new(AtomicUsize::new(0)))),
        1,
        Some(Arc::new(move || {
            let inner = callback_owner
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .upgrade()
                .unwrap();
            assert!(
                inner.registry.try_lock().is_ok(),
                "变更回调不能在登记锁内重入"
            );
            seen.lock()
                .unwrap()
                .push(TransferService { inner }.registry_snapshot());
        })),
    );
    *owner.lock().unwrap() = Some(Arc::downgrade(&service.inner));
    let id = service
        .start_operation(params(TransferDirection::Upload), |_| async {
            Ok(plan(1, true))
        })
        .unwrap()
        .unwrap();
    until(|| service.operation_status(&id).unwrap().status == TransferOperationStatus::HandedOff)
        .await;
    service.cancel_operation(&id).unwrap();
    service.shutdown();
    let snapshots = snapshots.lock().unwrap();
    assert!(snapshots
        .windows(2)
        .all(|pair| pair[1].revision > pair[0].revision));
    assert_eq!(snapshots[0].unfinished_summary().total, 1);
    assert_eq!(snapshots[1].unfinished_summary().total, 1);
    assert_eq!(snapshots[1].transfers.len(), 1);
}

#[tokio::test]
async fn operation_empty_group_keeps_execution_resources_after_scan() {
    let (service, _) = service();
    let id = service
        .start_operation(params(TransferDirection::Upload), |_| async {
            Ok(plan(0, true))
        })
        .unwrap()
        .unwrap();
    until(|| service.operation_status(&id).unwrap().status == TransferOperationStatus::HandedOff)
        .await;
    let resources = service
        .operation_params(&id)
        .expect("空目录也必须持有后续准备所需凭据");
    assert_eq!(
        resources.password.as_deref(),
        Some("test-only-password-marker")
    );
    assert_eq!(
        resources.passphrase.as_deref(),
        Some("test-only-passphrase-marker")
    );
    assert_eq!(resources.sources, params(TransferDirection::Upload).sources);
    assert!(service.operation_params("invalid").is_err());
    assert!(service
        .operation_params(&Uuid::new_v4().to_string())
        .is_err());
}
