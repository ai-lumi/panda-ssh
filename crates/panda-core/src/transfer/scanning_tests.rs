//! 只使用工作区临时目录和只读内存扫描器，不连接真实主机。
use super::*;
use crate::batch::{scan_local_sources, scan_remote_sources, RemoteSourceScanner, ScanOptions};
use crate::sftp::RemoteFile;
use crate::sftp_orchestration::{scan_local_orchestration, scan_remote_orchestration};
use russh_sftp::protocol::FileAttributes;
use std::sync::atomic::AtomicUsize;
use tokio::sync::oneshot;

type ScanFuture<'a, T> = Pin<Box<dyn Future<Output = crate::Result<T>> + Send + 'a>>;

struct FakeScanner {
    calls: Mutex<Vec<String>>,
    fail_list: bool,
    fail_metadata: bool,
    gate: Mutex<Option<oneshot::Receiver<()>>>,
}

impl FakeScanner {
    fn new() -> Self {
        Self {
            calls: Mutex::new(vec![]),
            fail_list: false,
            fail_metadata: false,
            gate: Mutex::new(None),
        }
    }
}

impl RemoteSourceScanner for FakeScanner {
    fn metadata<'a>(&'a self, path: &'a str) -> ScanFuture<'a, FileAttributes> {
        self.calls.lock().unwrap().push(format!("stat:{path}"));
        Box::pin(async move {
            if self.fail_metadata {
                return Err(Error::Other("无权读取元数据".into()));
            }
            let mut attrs = FileAttributes::default();
            attrs.permissions = Some(if path == "/remote/project" {
                0o040755
            } else {
                0o100644
            });
            attrs.size = Some(0);
            Ok(attrs)
        })
    }
    fn list_dir<'a>(&'a self, path: &'a str) -> ScanFuture<'a, Vec<RemoteFile>> {
        self.calls.lock().unwrap().push(format!("list:{path}"));
        let gate = self.gate.lock().unwrap().take();
        Box::pin(async move {
            if let Some(gate) = gate {
                let _ = gate.await;
            }
            if self.fail_list || path != "/remote/project" {
                return Err(Error::Other("目录不可读".into()));
            }
            Ok(vec![RemoteFile {
                name: "零 字节".into(),
                path: "/remote/project/零 字节".into(),
                is_dir: false,
                size: 0,
                modified: None,
            }])
        })
    }
    fn home_dir(&self) -> ScanFuture<'_, String> {
        Box::pin(async { Ok("/remote".into()) })
    }
}

struct NoWrites(Arc<AtomicUsize>);
impl TransferExecutor for NoWrites {
    fn execute(
        &self,
        _: TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { Ok(()) })
    }

    fn open_directory(
        &self,
        _: DirectoryContext,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn DirectoryWriter>, String>> + Send>> {
        Box::pin(std::future::pending())
    }
}

async fn settle(service: &TransferService, id: &str) -> TransferOperationSnapshot {
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let op = service.operation_status(id).unwrap();
            if op.status != TransferOperationStatus::Scanning {
                return op;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn scanning_remote_list_error_is_not_a_zero_byte_file() {
    let mut scanner = FakeScanner::new();
    scanner.fail_list = true;
    let result = scan_remote_sources(
        &scanner,
        &["/remote/project".into()],
        "/local",
        &ScanOptions::default(),
    )
    .await;
    assert!(result.is_err(), "不能把不可读目录降级为零字节文件");
    assert!(result.unwrap_err().to_string().contains("/remote/project"));
}

#[tokio::test]
async fn scanning_remote_metadata_error_is_not_empty_success() {
    let mut scanner = FakeScanner::new();
    scanner.fail_metadata = true;
    let result = scan_remote_sources(
        &scanner,
        &["/remote/file".into()],
        "/local",
        &ScanOptions::default(),
    )
    .await;
    assert!(result.is_err(), "不能吞掉元数据错误");
    assert!(result.unwrap_err().to_string().contains("/remote/file"));
}

#[tokio::test]
async fn scanning_local_error_contains_failing_source() {
    let temp = tempfile::tempdir().unwrap();
    let missing = temp.path().join("消失 空间");
    let result = scan_local_sources(&[missing.clone()], "/remote", &ScanOptions::default()).await;
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains(missing.to_str().unwrap()),
        "错误必须定位源路径"
    );
}

#[tokio::test]
async fn scanning_local_overlap_keeps_parent_mapping_and_counts_files_once() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    let sub = root.join("sub");
    std::fs::create_dir_all(&sub).unwrap();
    let file = sub.join("file");
    std::fs::write(&file, b"123").unwrap();
    let plan = scan_local_sources(
        &[file.clone(), sub.clone(), root.clone(), root.clone()],
        "/target",
        &ScanOptions::default(),
    )
    .await
    .unwrap();
    assert_eq!(plan.total_size, 3, "重叠选择不能重复扫描计数");
    assert_eq!(plan.items.len(), 3);
    assert_eq!(
        plan.items.iter().find(|i| !i.is_dir).unwrap().destination,
        "/target/project/sub/file"
    );
}

#[tokio::test]
async fn scanning_fixed_destination_once_despite_navigation_and_overlap() {
    let writes = Arc::new(AtomicUsize::new(0));
    let service = TransferService::new(Box::new(NoWrites(writes.clone())));
    let scanner = Arc::new(FakeScanner::new());
    let (release, gate) = oneshot::channel();
    *scanner.gate.lock().unwrap() = Some(gate);
    let scan = scanner.clone();
    let mut navigation = "/local/原始 目标".to_string();
    let params = TransferOperationParams {
        direction: TransferDirection::Download,
        host_id: "fake".into(),
        sources: vec![
            "/remote/project/零 字节".into(),
            "/remote/project".into(),
            "/remote/project".into(),
        ],
        destination_dir: navigation.clone(),
        password: None,
        passphrase: None,
    };
    let id = service
        .start_operation(params, move |input| async move {
            scan_remote_orchestration(
                scan.as_ref(),
                &input.sources,
                &input.destination_dir,
                &ScanOptions::default(),
            )
            .await
        })
        .unwrap()
        .unwrap();
    assert_eq!(
        service.operation_status(&id).unwrap().status,
        TransferOperationStatus::Scanning
    );
    navigation = "/local/后来".into();
    release.send(()).unwrap();
    let op = settle(&service, &id).await;
    assert_eq!(
        op.status,
        TransferOperationStatus::HandedOff,
        "实际扫描需完成交接"
    );
    assert_ne!(op.destination_dir, navigation);
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.transfers.len(), 1);
    assert_eq!(snapshot.groups.len(), 1);
    assert_eq!(
        snapshot.transfers[0].local_path,
        "/local/原始 目标/project/零 字节"
    );
    let calls = scanner.calls.lock().unwrap();
    for expected in [
        "stat:/remote/project",
        "stat:/remote/project/零 字节",
        "list:/remote/project",
    ] {
        assert_eq!(
            calls.iter().filter(|s| s.as_str() == expected).count(),
            1,
            "每个路径只扫描一次: {calls:?}"
        );
    }
    assert_eq!(calls.len(), 3, "文件不得尝试目录读取");
    assert_eq!(writes.load(Ordering::SeqCst), 0, "目录未准备不得写入");
}

#[tokio::test]
async fn scanning_partial_local_failure_and_unreadable_remote_never_enqueue() {
    for direction in [TransferDirection::Upload, TransferDirection::Download] {
        let temp = tempfile::tempdir().unwrap();
        let good = temp.path().join("a-good");
        let missing = temp.path().join("z-missing");
        std::fs::write(&good, b"good").unwrap();
        let writes = Arc::new(AtomicUsize::new(0));
        let service = TransferService::new(Box::new(NoWrites(writes.clone())));
        let sources = if direction == TransferDirection::Upload {
            vec![
                good.to_string_lossy().into_owned(),
                missing.to_string_lossy().into_owned(),
            ]
        } else {
            vec!["/remote/project".into()]
        };
        let id = service
            .start_operation(
                TransferOperationParams {
                    direction,
                    host_id: "fake".into(),
                    sources,
                    destination_dir: "/target".into(),
                    password: None,
                    passphrase: None,
                },
                move |input| async move {
                    if direction == TransferDirection::Upload {
                        scan_local_orchestration(
                            &input.sources,
                            &input.destination_dir,
                            &ScanOptions::default(),
                        )
                        .await
                    } else {
                        let mut scan = FakeScanner::new();
                        scan.fail_list = true;
                        scan_remote_orchestration(
                            &scan,
                            &input.sources,
                            &input.destination_dir,
                            &ScanOptions::default(),
                        )
                        .await
                    }
                },
            )
            .unwrap()
            .unwrap();
        let op = settle(&service, &id).await;
        assert_eq!(op.status, TransferOperationStatus::Failed);
        let expected = if direction == TransferDirection::Upload {
            missing.to_str().unwrap()
        } else {
            "/remote/project"
        };
        assert!(op.error.unwrap().contains(expected));
        let snapshot = service.registry_snapshot();
        assert!(snapshot.transfers.is_empty() && snapshot.groups.is_empty());
        assert_eq!(writes.load(Ordering::SeqCst), 0);
    }
}

#[cfg(unix)]
#[tokio::test]
async fn scanning_local_unreadable_directory_is_pathful_failure() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("不可读");
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
    let result = scan_local_sources(&[root.clone()], "/target", &ScanOptions::default()).await;
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(result
        .unwrap_err()
        .to_string()
        .contains(root.to_str().unwrap()));
}

#[tokio::test]
async fn scanning_thousand_files_cycle_and_empty_subdirectories_stay_queued() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("中文 空间");
    std::fs::create_dir_all(root.join("empty/sub")).unwrap();
    for i in 0..1000 {
        std::fs::write(root.join(format!("file-{i}")), b"").unwrap();
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(&root, root.join("loop")).unwrap();
    let writes = Arc::new(AtomicUsize::new(0));
    let service = TransferService::new(Box::new(NoWrites(writes.clone())));
    let id = service
        .start_operation(
            TransferOperationParams {
                direction: TransferDirection::Upload,
                host_id: "fake".into(),
                sources: vec![root.to_string_lossy().into_owned()],
                destination_dir: "/target".into(),
                password: None,
                passphrase: None,
            },
            |input| async move {
                scan_local_orchestration(
                    &input.sources,
                    &input.destination_dir,
                    &ScanOptions {
                        follow_symlinks: true,
                        max_depth: 100,
                    },
                )
                .await
            },
        )
        .unwrap()
        .unwrap();
    assert_eq!(
        service.operation_status(&id).unwrap().status,
        TransferOperationStatus::Scanning
    );
    let op = settle(&service, &id).await;
    assert_eq!(op.status, TransferOperationStatus::HandedOff);
    let snapshot = service.registry_snapshot();
    assert_eq!(snapshot.transfers.len(), 1000);
    assert_eq!(snapshot.groups.len(), 1);
    assert!(snapshot.groups[0]
        .plan
        .directories
        .iter()
        .any(|d| d.destination == "/target/中文 空间/empty/sub"));
    assert!(snapshot
        .transfers
        .iter()
        .all(|t| t.status == TransferStatus::Queued && t.size == 0));
    assert_eq!(snapshot.unfinished_summary().total, 1);
    assert_eq!(writes.load(Ordering::SeqCst), 0);
    service.shutdown();
}
