use super::*;
use crate::sftp_orchestration::{plan_sftp_orchestration, SftpOrchestrationDirection};
use crate::task_aggregation::TaskItem;
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

struct IoCall {
    path: String,
    directory: bool,
    release: oneshot::Sender<Result<(), String>>,
}

struct ControlledIo {
    calls: mpsc::UnboundedSender<IoCall>,
    counts: Arc<ExecutionCounts>,
}

struct ControlledDirectory {
    calls: mpsc::UnboundedSender<IoCall>,
    _active: ActiveExecution,
}

impl DirectoryWriter for ControlledDirectory {
    fn create_dir_all<'a>(
        &'a self,
        path: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send + 'a>> {
        Box::pin(async move {
            let (release, receiver) = oneshot::channel();
            self.calls
                .send(IoCall {
                    path: path.into(),
                    directory: true,
                    release,
                })
                .unwrap();
            receiver
                .await
                .unwrap_or_else(|_| Err("测试执行已释放".into()))
        })
    }
}

impl TransferExecutor for ControlledIo {
    fn execute(
        &self,
        ctx: TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        let calls = self.calls.clone();
        let active = ActiveExecution::new(self.counts.clone());
        Box::pin(async move {
            let _active = active;
            let (release, receiver) = oneshot::channel();
            let path = match ctx.direction {
                TransferDirection::Upload => ctx.remote_path,
                TransferDirection::Download => ctx.local_path,
            };
            calls
                .send(IoCall {
                    path,
                    directory: false,
                    release,
                })
                .unwrap();
            receiver
                .await
                .unwrap_or_else(|_| Err("测试执行已释放".into()))
        })
    }

    fn open_directory(
        &self,
        _: DirectoryContext,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn DirectoryWriter>, String>> + Send>> {
        let writer = ControlledDirectory {
            calls: self.calls.clone(),
            _active: ActiveExecution::new(self.counts.clone()),
        };
        Box::pin(async move { Ok(Box::new(writer) as Box<dyn DirectoryWriter>) })
    }
}

fn controlled(
    concurrency: usize,
) -> (
    TransferService,
    mpsc::UnboundedReceiver<IoCall>,
    Arc<ExecutionCounts>,
) {
    let (calls, receiver) = mpsc::unbounded_channel();
    let counts = Arc::new(ExecutionCounts::default());
    let service = TransferService::with_concurrency(
        Box::new(ControlledIo {
            calls,
            counts: counts.clone(),
        }),
        concurrency,
        None,
    );
    (service, receiver, counts)
}

async fn next_call(calls: &mut mpsc::UnboundedReceiver<IoCall>) -> IoCall {
    tokio::time::timeout(Duration::from_secs(2), calls.recv())
        .await
        .expect("准备或文件必须被调度")
        .unwrap()
}

async fn until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("准备状态未到达预期");
}

async fn wait_handed_off(service: &TransferService, operation: &str) -> Vec<String> {
    until(|| {
        service.operation_status(operation).unwrap().status
            == TransferOperationStatus::HandedOff
    })
    .await;
    service.operation_status(operation).unwrap().group_ids
}

fn start_group(
    service: &TransferService,
    name: &str,
    files: usize,
    direction: TransferDirection,
) -> String {
    let source = format!("/source/{name}");
    let destination = format!("/target/{name}");
    let mut items = vec![TaskItem {
        source: source.clone(),
        destination: destination.clone(),
        name: name.into(),
        size: 0,
        is_dir: true,
    }];
    items.extend((0..files).map(|i| TaskItem {
        source: format!("{source}/{i}"),
        destination: format!("{destination}/{i}"),
        name: i.to_string(),
        size: 0,
        is_dir: false,
    }));
    let sources = vec![source];
    let plan = plan_sftp_orchestration(
        &sources,
        &items,
        match direction {
            TransferDirection::Upload => SftpOrchestrationDirection::Upload,
            TransferDirection::Download => SftpOrchestrationDirection::Download,
        },
    );
    service
        .start_operation(
            TransferOperationParams {
                direction,
                host_id: "fake".into(),
                sources,
                destination_dir: "/target".into(),
                password: None,
                passphrase: None,
            },
            |_| async move { Ok(plan) },
        )
        .unwrap()
        .unwrap()
}

#[tokio::test]
async fn directory_preparation_and_files_share_one_slot_without_deadlock() {
    for direction in [TransferDirection::Upload, TransferDirection::Download] {
        let (service, mut calls, counts) = controlled(1);
        let operation = start_group(&service, "中文 空目录", 2, direction);
        let preparation = next_call(&mut calls).await;
        assert!(preparation.directory);
        assert_eq!(preparation.path, "/target/中文 空目录");
        let snapshot = service.registry_snapshot();
        assert_eq!(snapshot.transfers.len(), 2);
        assert!(snapshot
            .transfers
            .iter()
            .all(|t| t.status == TransferStatus::Queued));
        assert_eq!(snapshot.groups[0].status, TransferStatus::Running);
        assert_eq!(counts.active.load(Ordering::SeqCst), 1);
        assert!(calls.try_recv().is_err());
        preparation.release.send(Ok(())).unwrap();
        for _ in 0..2 {
            let file = next_call(&mut calls).await;
            assert!(!file.directory);
            assert_eq!(counts.active.load(Ordering::SeqCst), 1);
            assert!(calls.try_recv().is_err());
            file.release.send(Ok(())).unwrap();
        }
        until(|| {
            service
                .transfer_list()
                .iter()
                .all(|t| t.status == TransferStatus::Completed)
        })
        .await;
        assert_eq!(
            service.operation_status(&operation).unwrap().task_ids.len(),
            2
        );
        assert_eq!(counts.peak.load(Ordering::SeqCst), 1);
    }
}

#[tokio::test]
async fn preparation_and_existing_download_compete_for_three_slots() {
    let (service, mut calls, counts) = controlled(3);
    service
        .start_transfer(TransferParams {
            direction: TransferDirection::Download,
            host_id: "fake".into(),
            local_path: "/target/download".into(),
            remote_path: "/source/download".into(),
            size: 1,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        })
        .unwrap();
    let download = next_call(&mut calls).await;
    assert!(!download.directory);
    for name in ["a", "b", "c", "d"] {
        start_group(&service, name, 1, TransferDirection::Upload);
    }
    let first = next_call(&mut calls).await;
    let second = next_call(&mut calls).await;
    assert!(first.directory && second.directory);
    assert_eq!(counts.active.load(Ordering::SeqCst), 3);
    assert!(calls.try_recv().is_err());
    download.release.send(Ok(())).unwrap();
    first.release.send(Ok(())).unwrap();
    second.release.send(Ok(())).unwrap();
    for _ in 0..6 {
        next_call(&mut calls).await.release.send(Ok(())).unwrap();
    }
    until(|| counts.active.load(Ordering::SeqCst) == 0).await;
    assert_eq!(counts.peak.load(Ordering::SeqCst), 3);
    assert!(service
        .transfer_list()
        .iter()
        .all(|t| t.status == TransferStatus::Completed));
}

#[tokio::test]
async fn zero_file_group_completes_only_after_directory_preparation() {
    let (service, mut calls, _) = controlled(1);
    let operation = start_group(&service, "empty", 0, TransferDirection::Upload);
    let preparation = next_call(&mut calls).await;
    let before = service.registry_snapshot();
    assert!(before.transfers.is_empty());
    assert_eq!(before.groups[0].status, TransferStatus::Running);
    assert_eq!(before.unfinished_summary().total, 1);
    preparation.release.send(Ok(())).unwrap();
    until(|| service.registry_snapshot().groups[0].status == TransferStatus::Completed).await;
    assert_eq!(
        service.operation_status(&operation).unwrap().task_ids.len(),
        0
    );
    assert_eq!(service.registry_snapshot().unfinished_summary().total, 0);
    assert!(service.registry_snapshot().revision > before.revision);
}

#[tokio::test]
async fn directory_failure_blocks_dependent_files_without_execution() {
    let (service, mut calls, counts) = controlled(1);
    start_group(&service, "blocked", 2, TransferDirection::Upload);
    let preparation = next_call(&mut calls).await;
    preparation
        .release
        .send(Err("Permission denied".into()))
        .unwrap();
    until(|| service.registry_snapshot().groups[0].status == TransferStatus::Failed).await;
    assert!(service
        .transfer_list()
        .iter()
        .all(|t| t.status == TransferStatus::Failed));
    assert!(service.transfer_list().iter().all(|t| t
        .error
        .as_ref()
        .is_some_and(|e| e.contains("/source/blocked") && e.contains("/target/blocked"))));
    assert!(calls.try_recv().is_err());
    assert_eq!(counts.active.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn cancelled_preparation_never_releases_members_and_frees_slot() {
    let (service, mut calls, counts) = controlled(1);
    let operation = start_group(&service, "cancelled", 2, TransferDirection::Upload);
    let preparation = next_call(&mut calls).await;
    service.cancel_operation(&operation).unwrap();
    let _ = preparation.release.send(Ok(()));
    until(|| counts.active.load(Ordering::SeqCst) == 0).await;
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.groups[0].status, TransferStatus::Cancelled);
    assert!(snapshot
        .transfers
        .iter()
        .all(|t| t.status == TransferStatus::Cancelled));
    assert!(calls.try_recv().is_err());
    start_group(&service, "next", 0, TransferDirection::Upload);
    next_call(&mut calls).await.release.send(Ok(())).unwrap();
}

fn start_tree(service: &TransferService, entries: &[(&str, bool)]) -> String {
    let sources = vec!["/source/tree".into()];
    let items = entries.iter().map(|(path, is_dir)| TaskItem {
        source: format!("/source/tree{path}"),
        destination: format!("/target/tree{path}"),
        name: path.rsplit('/').next().unwrap().into(),
        size: 0,
        is_dir: *is_dir,
    }).collect::<Vec<_>>();
    let plan = plan_sftp_orchestration(&sources, &items, SftpOrchestrationDirection::Upload);
    service.start_operation(TransferOperationParams {
        direction: TransferDirection::Upload,
        host_id: "fake".into(), sources, destination_dir: "/target".into(),
        password: None, passphrase: None,
    }, |_| async move { Ok(plan) }).unwrap().unwrap()
}

#[tokio::test]
async fn directory_empty_child_failure_does_not_block_writable_sibling() {
    let (service, mut calls, _) = controlled(1);
    start_tree(&service, &[("", true), ("/blocked", true), ("/ok.txt", false)]);
    next_call(&mut calls).await.release.send(Ok(())).unwrap();
    let blocked = next_call(&mut calls).await;
    assert_eq!(blocked.path, "/target/tree/blocked");
    blocked.release.send(Err("Permission denied".into())).unwrap();
    let file = next_call(&mut calls).await;
    assert_eq!(file.path, "/target/tree/ok.txt");
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_list()[0].status == TransferStatus::Completed).await;
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.groups[0].status, TransferStatus::Failed);
    let error = snapshot.groups[0].error.as_ref().unwrap();
    assert!(error.contains("/source/tree/blocked") && error.contains("/target/tree/blocked"));
}

#[tokio::test]
async fn directory_failed_parent_only_blocks_descendants_and_keeps_empty_siblings() {
    let (service, mut calls, _) = controlled(1);
    start_tree(&service, &[("", true), ("/bad", true), ("/bad/sub", true),
        ("/bad/sub/file", false), ("/good", true), ("/good/empty", true), ("/good/file", false)]);
    next_call(&mut calls).await.release.send(Ok(())).unwrap();
    let bad = next_call(&mut calls).await;
    assert_eq!(bad.path, "/target/tree/bad");
    bad.release.send(Err("not a directory".into())).unwrap();
    for expected in ["/target/tree/good", "/target/tree/good/empty"] {
        let directory = next_call(&mut calls).await;
        assert!(directory.directory);
        assert_eq!(directory.path, expected);
        directory.release.send(Ok(())).unwrap();
    }
    let file = next_call(&mut calls).await;
    assert_eq!(file.path, "/target/tree/good/file");
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_list().iter().all(|t| t.status.is_terminal())).await;
    let tasks = service.transfer_list();
    assert_eq!(tasks.iter().find(|t| t.remote_path.contains("/bad/")).unwrap().status, TransferStatus::Failed);
    assert_eq!(tasks.iter().find(|t| t.remote_path.contains("/good/")).unwrap().status, TransferStatus::Completed);
}

#[tokio::test]
async fn directory_connection_failure_contains_source_and_destination() {
    struct NoDirectory;
    impl TransferExecutor for NoDirectory {
        fn execute(&self, _: TransferContext) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
            panic!("准备失败不得写入")
        }
    }
    let service = TransferService::new(Box::new(NoDirectory));
    start_tree(&service, &[("", true), ("/file", false)]);
    until(|| service.registry_snapshot().groups.first().is_some_and(|g| g.status == TransferStatus::Failed)).await;
    let snapshot = service.registry_snapshot();
    let error = snapshot.groups[0].error.as_ref().unwrap();
    assert!(error.contains("/source/tree") && error.contains("/target/tree"), "{error}");
    assert!(snapshot.transfers[0].error.as_ref().unwrap().contains("/source/tree"));
}

#[tokio::test]
async fn file_disappearing_after_queue_keeps_both_paths_and_siblings_execute() {
    let (service, mut calls, _) = controlled(1);
    start_tree(&service, &[("", true), ("/missing", false), ("/sibling", false)]);
    next_call(&mut calls).await.release.send(Ok(())).unwrap();
    for _ in 0..2 {
        let file = next_call(&mut calls).await;
        let result = if file.path.ends_with("/missing") { Err("No such file".into()) } else { Ok(()) };
        file.release.send(result).unwrap();
    }
    until(|| service.transfer_list().iter().all(|t| t.status.is_terminal())).await;
    let tasks = service.transfer_list();
    let missing = tasks.iter().find(|t| t.remote_path.ends_with("/missing")).unwrap();
    assert_eq!(missing.status, TransferStatus::Failed);
    let error = missing.error.as_ref().unwrap();
    assert!(error.contains("/source/tree/missing") && error.contains("/target/tree/missing"), "{error}");
    assert_eq!(tasks.iter().find(|t| t.remote_path.ends_with("/sibling")).unwrap().status, TransferStatus::Completed);
}

#[tokio::test]
async fn group_cancel_during_preparation_cancels_directory_and_members() {
    let (service, mut calls, counts) = controlled(1);
    let operation = start_group(&service, "grp", 2, TransferDirection::Upload);
    let group_ids = wait_handed_off(&service, &operation).await;
    let group_id = group_ids[0].clone();
    let preparation = next_call(&mut calls).await;
    assert!(preparation.directory);
    service.group_cancel(&group_id).unwrap();
    let _ = preparation.release.send(Ok(()));
    until(|| counts.active.load(Ordering::SeqCst) == 0).await;
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.groups[0].status, TransferStatus::Cancelled);
    assert!(snapshot
        .transfers
        .iter()
        .all(|t| t.status == TransferStatus::Cancelled));
    assert!(calls.try_recv().is_err());
}

#[tokio::test]
async fn group_retry_after_preparation_failure_reruns_preparation() {
    let (service, mut calls, _) = controlled(1);
    let operation = start_group(&service, "retry", 1, TransferDirection::Upload);
    let group_ids = wait_handed_off(&service, &operation).await;
    let group_id = group_ids[0].clone();
    next_call(&mut calls).await.release.send(Err("Permission denied".into())).unwrap();
    until(|| service.registry_snapshot().groups[0].status == TransferStatus::Failed).await;
    assert!(service.transfer_list()[0].status == TransferStatus::Failed);
    service.group_retry(&group_id).unwrap();
    let preparation = next_call(&mut calls).await;
    assert!(preparation.directory);
    assert_eq!(preparation.path, "/target/retry");
    preparation.release.send(Ok(())).unwrap();
    let file = next_call(&mut calls).await;
    assert!(!file.directory);
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_list().iter().all(|t| t.status == TransferStatus::Completed)).await;
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.groups[0].status, TransferStatus::Completed);
}

#[tokio::test]
async fn single_file_retry_after_preparation_failure_restores_directory() {
    let (service, mut calls, _) = controlled(1);
    let operation = start_group(&service, "single", 2, TransferDirection::Upload);
    let _group_ids = wait_handed_off(&service, &operation).await;
    next_call(&mut calls).await.release.send(Err("Permission denied".into())).unwrap();
    until(|| service.registry_snapshot().groups[0].status == TransferStatus::Failed).await;
    let task_id = service.transfer_list()[0].id.clone();
    service.transfer_retry(&task_id).unwrap();
    let preparation = next_call(&mut calls).await;
    assert!(preparation.directory);
    assert_eq!(preparation.path, "/target/single");
    preparation.release.send(Ok(())).unwrap();
    let file = next_call(&mut calls).await;
    assert!(!file.directory);
    file.release.send(Ok(())).unwrap();
    until(|| service.transfer_list().iter().any(|t| t.status == TransferStatus::Completed)).await;
}

#[tokio::test]
async fn group_pause_during_preparation_does_not_cancel_preparation() {
    let (service, mut calls, counts) = controlled(2);
    let operation = start_group(&service, "pause", 2, TransferDirection::Upload);
    let group_ids = wait_handed_off(&service, &operation).await;
    let group_id = group_ids[0].clone();
    let preparation = next_call(&mut calls).await;
    assert!(preparation.directory);
    service.group_pause(&group_id).unwrap();
    until(|| {
        service
            .transfer_list()
            .iter()
            .all(|t| t.status == TransferStatus::Paused)
    })
    .await;
    assert_eq!(service.registry_snapshot().groups[0].status, TransferStatus::Running);
    assert_eq!(counts.active.load(Ordering::SeqCst), 1);
    preparation.release.send(Ok(())).unwrap();
    service.group_resume(&group_id).unwrap();
    for _ in 0..2 {
        let file = next_call(&mut calls).await;
        assert!(!file.directory);
        file.release.send(Ok(())).unwrap();
    }
    until(|| service.transfer_list().iter().all(|t| t.status == TransferStatus::Completed)).await;
}

#[tokio::test]
async fn cancel_race_with_preparation_completion_does_not_release_members() {
    let (service, mut calls, counts) = controlled(1);
    let operation = start_group(&service, "race", 2, TransferDirection::Upload);
    let group_ids = wait_handed_off(&service, &operation).await;
    let group_id = group_ids[0].clone();
    let preparation = next_call(&mut calls).await;
    service.group_cancel(&group_id).unwrap();
    let _ = preparation.release.send(Ok(()));
    until(|| counts.active.load(Ordering::SeqCst) == 0).await;
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.groups[0].status, TransferStatus::Cancelled);
    assert!(snapshot
        .transfers
        .iter()
        .all(|t| t.status == TransferStatus::Cancelled));
    assert!(calls.try_recv().is_err());
}
