use panda_core::delete_tasks::*;
use panda_core::task_summary::{WorkKind, WorkStatus};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

#[derive(Clone, Default)]
struct FakeFs {
    nodes: BTreeMap<String, NodeKind>,
    removed: Arc<Mutex<Vec<String>>>,
    fail_scan: Option<String>,
    fail_remove: Option<(String, bool)>,
    cancelled: Option<DeleteTask>,
    closed: Arc<AtomicBool>,
    invalid_child: bool,
}

impl DeleteFileSystem for FakeFs {
    async fn inspect(&self, path: &str) -> Result<NodeKind, DeleteError> {
        self.nodes.get(path).copied().ok_or(DeleteError::new("不存在", false))
    }
    async fn children(&self, path: &str) -> Result<Vec<String>, DeleteError> {
        if self.fail_scan.as_deref() == Some(path) { return Err(DeleteError::new("扫描失败", false)); }
        if self.invalid_child { return Ok(vec!["../outside".into()]); }
        let prefix = format!("{path}/");
        Ok(self.nodes.keys().filter_map(|p| p.strip_prefix(&prefix))
            .filter(|p| !p.contains('/')).map(str::to_owned).collect())
    }
    async fn remove(&self, path: &str, _: NodeKind) -> Result<(), DeleteError> {
        self.removed.lock().unwrap().push(path.into());
        if let Some(task) = &self.cancelled { task.cancel(); task.cancel(); }
        if let Some((failure, fatal)) = &self.fail_remove {
            if path == failure { return Err(DeleteError::new("删除失败", *fatal)); }
        }
        Ok(())
    }
    async fn close(&self) { self.closed.store(true, Ordering::SeqCst); }
}

fn task(paths: &[&str]) -> DeleteTask {
    DeleteTask::new("delete".into(), WorkKind::LocalDelete, paths.iter().map(|p| (*p).into()).collect(), Arc::new(|| {})).unwrap()
}

fn tree() -> FakeFs {
    FakeFs { nodes: [("/tree", NodeKind::Directory), ("/tree/a", NodeKind::Directory),
        ("/tree/a/file", NodeKind::File), ("/tree/link", NodeKind::Symlink)]
        .into_iter().map(|(p,k)| (p.into(),k)).collect(), ..Default::default() }
}

#[tokio::test]
async fn postorder_counts_directories_and_does_not_follow_links() {
    let fs = tree(); let audit = fs.clone(); let task = task(&["/tree", "/tree/a"]);
    task.run(fs).await;
    let snapshot = task.snapshot();
    assert_eq!(*audit.removed.lock().unwrap(), ["/tree/a/file", "/tree/a", "/tree/link", "/tree"]);
    assert_eq!((snapshot.processed, snapshot.succeeded, snapshot.total), (4, 4, Some(4)));
    assert_eq!(snapshot.status, WorkStatus::Completed);
    assert!(audit.closed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn scan_failure_or_escaping_child_deletes_nothing_and_total_remains_unknown() {
    for invalid_child in [false, true] {
        let fs = FakeFs { fail_scan: if invalid_child { None } else { Some("/tree/a".into()) }, invalid_child, ..tree() };
        let audit = fs.clone(); let task = task(&["/tree"]); task.run(fs).await;
        assert!(audit.removed.lock().unwrap().is_empty());
        assert_eq!(task.snapshot().status, WorkStatus::Failed);
        assert_eq!(task.snapshot().total, None);
        assert!(audit.closed.load(Ordering::SeqCst));
    }
}

#[tokio::test]
async fn permission_failure_continues_but_disconnect_stops() {
    for fatal in [false, true] {
        let fs = FakeFs { fail_remove: Some(("/tree/a/file".into(), fatal)), ..tree() };
        let task = task(&["/tree"]); task.run(fs).await;
        let s = task.snapshot(); assert_eq!(s.status, WorkStatus::Failed);
        assert_eq!(s.errors.len(), 1); assert_eq!(s.processed, if fatal { 1 } else { 4 });
        assert_eq!(s.succeeded, if fatal { 0 } else { 3 });
    }
}

#[tokio::test]
async fn cancellation_waits_for_current_operation_and_preserves_counts() {
    let task = task(&["/tree"]);
    let fs = FakeFs { cancelled: Some(task.clone()), ..tree() };
    let audit = fs.clone(); task.run(fs).await;
    assert_eq!(task.snapshot().status, WorkStatus::Cancelled);
    assert_eq!(task.snapshot().processed, 1);
    assert_eq!(audit.removed.lock().unwrap().len(), 1);
    assert!(audit.closed.load(Ordering::SeqCst));
    task.cancel(); assert_eq!(task.snapshot().status, WorkStatus::Cancelled);
}

#[tokio::test]
async fn cancelling_before_scan_releases_resources_without_file_operations() {
    let fs = tree(); let audit = fs.clone(); let task = task(&["/tree"]);
    task.cancel(); assert_eq!(task.snapshot().status, WorkStatus::Cancelling);
    task.run(fs).await;
    assert_eq!(task.snapshot().status, WorkStatus::Cancelled);
    assert!(audit.removed.lock().unwrap().is_empty());
    assert!(audit.closed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn deep_tree_uses_explicit_stack_and_empty_directory_counts_as_one() {
    let mut fs = FakeFs::default(); let mut path = "/tree".to_string();
    for _ in 0..2048 { fs.nodes.insert(path.clone(), NodeKind::Directory); path.push_str("/d"); }
    let task = task(&["/tree"]); task.run(fs).await;
    assert_eq!(task.snapshot().total, Some(2048));
    assert_eq!(task.snapshot().succeeded, 2048);
}

#[test]
fn rejects_empty_root_relative_and_parent_traversal_targets() {
    for paths in [vec![], vec![""], vec!["/"], vec!["//"], vec!["relative"], vec!["/a/../b"], vec!["/a/./b"], vec!["/a\0b"]] {
        assert!(DeleteTask::new("id".into(), WorkKind::LocalDelete,
            paths.iter().map(|p| (*p).into()).collect(), Arc::new(|| {})).is_err());
    }
}

#[tokio::test]
async fn local_fixture_removes_only_link_not_its_target() {
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("tree"); std::fs::create_dir(&root).unwrap();
    let outside = fixture.path().join("outside"); std::fs::write(&outside, b"preserve").unwrap();
    #[cfg(unix)] std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
    let task = task(&[root.to_str().unwrap()]); task.run(LocalDeleteFileSystem).await;
    assert!(!root.exists()); assert_eq!(std::fs::read(outside).unwrap(), b"preserve");
    assert_eq!(task.snapshot().status, WorkStatus::Completed);
}
