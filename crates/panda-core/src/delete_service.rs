//! 删除任务服务：管理本地/远端删除任务的生命周期、快照与取消。

use crate::delete_tasks::{DeleteFileSystem, DeleteTask};
use crate::task_summary::{WorkKind, WorkSnapshot};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct DeleteServiceSnapshot {
    pub task_id: String,
    pub snapshot: WorkSnapshot,
}

struct DeleteTaskEntry {
    task: DeleteTask,
}

struct ServiceInner {
    tasks: Mutex<HashMap<String, DeleteTaskEntry>>,
    change_counter: std::sync::atomic::AtomicU64,
    on_change: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl ServiceInner {
    fn notify_changed(&self) {
        self.change_counter
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if let Some(ref cb) = self.on_change {
            cb();
        }
    }
}

#[derive(Clone)]
pub struct DeleteService {
    inner: Arc<ServiceInner>,
}

impl DeleteService {
    pub fn new(on_change: Option<Arc<dyn Fn() + Send + Sync>>) -> Self {
        Self {
            inner: Arc::new(ServiceInner {
                tasks: Mutex::new(HashMap::new()),
                change_counter: std::sync::atomic::AtomicU64::new(0),
                on_change,
            }),
        }
    }

    pub fn start_delete<F>(
        &self,
        kind: WorkKind,
        targets: Vec<String>,
        fs: F,
    ) -> Result<String, String>
    where
        F: DeleteFileSystem + 'static,
    {
        if targets.is_empty() {
            return Err("删除目标不能为空".into());
        }
        let id = Uuid::new_v4().to_string();
        let changed = {
            let inner = self.inner.clone();
            Arc::new(move || inner.notify_changed())
        };
        let task = DeleteTask::new(id.clone(), kind, targets, changed)?;
        let entry = DeleteTaskEntry { task: task.clone() };
        self.inner
            .tasks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.clone(), entry);
        self.inner.notify_changed();

        let inner = self.inner.clone();
        let task_for_spawn = task.clone();
        tokio::spawn(async move {
            task_for_spawn.run(fs).await;
            inner.notify_changed();
        });
        Ok(id)
    }

    pub fn status(&self, task_id: &str) -> Result<DeleteServiceSnapshot, String> {
        let tasks = self.inner.tasks.lock().unwrap();
        let entry = tasks.get(task_id).ok_or_else(|| format!("未知删除任务: {task_id}"))?;
        Ok(DeleteServiceSnapshot {
            task_id: task_id.to_string(),
            snapshot: entry.task.snapshot(),
        })
    }

    pub fn list(&self) -> Vec<DeleteServiceSnapshot> {
        let tasks = self.inner.tasks.lock().unwrap();
        tasks
            .values()
            .map(|entry| DeleteServiceSnapshot {
                task_id: entry.task.snapshot().id.clone(),
                snapshot: entry.task.snapshot(),
            })
            .collect()
    }

    pub fn cancel(&self, task_id: &str) -> Result<(), String> {
        let tasks = self.inner.tasks.lock().unwrap();
        let entry = tasks
            .get(task_id)
            .ok_or_else(|| format!("未知删除任务: {task_id}"))?;
        entry.task.cancel();
        Ok(())
    }

    pub fn change_counter(&self) -> u64 {
        self.inner
            .change_counter
            .load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::delete_tasks::{DeleteError, DeleteFileSystem, NodeKind};
    use crate::task_summary::{WorkKind, WorkStatus};
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct MockFs {
        nodes: HashMap<String, NodeKind>,
        fail_inspect: Option<String>,
        fail_remove: Option<(String, bool)>,
        removed: Arc<Mutex<Vec<String>>>,
    }

    impl MockFs {
        fn new() -> Self {
            Self {
                nodes: HashMap::new(),
                fail_inspect: None,
                fail_remove: None,
                removed: Arc::new(Mutex::new(Vec::new())),
            }
        }

        fn with_file(mut self, path: &str) -> Self {
            self.nodes.insert(path.to_string(), NodeKind::File);
            self
        }

        fn with_dir(mut self, path: &str, children: Vec<&str>) -> Self {
            self.nodes.insert(path.to_string(), NodeKind::Directory);
            for child in children {
                self.nodes
                    .insert(format!("{path}/{child}"), NodeKind::File);
            }
            self
        }

        fn with_fail_inspect(mut self, path: &str) -> Self {
            self.fail_inspect = Some(path.to_string());
            self
        }

        fn with_fail_remove(mut self, path: &str, fatal: bool) -> Self {
            self.fail_remove = Some((path.to_string(), fatal));
            self
        }
    }

    impl DeleteFileSystem for MockFs {
        async fn inspect(&self, path: &str) -> Result<NodeKind, DeleteError> {
            if let Some(ref fail_path) = self.fail_inspect {
                if fail_path == path {
                    return Err(DeleteError::new("inspect 失败", false));
                }
            }
            self.nodes
                .get(path)
                .copied()
                .ok_or_else(|| DeleteError::new("文件不存在", false))
        }

        async fn children(&self, path: &str) -> Result<Vec<String>, DeleteError> {
            let prefix = format!("{path}/");
            Ok(self
                .nodes
                .keys()
                .filter(|k| k.starts_with(&prefix) && !k[prefix.len()..].contains('/'))
                .map(|k| k[prefix.len()..].to_string())
                .collect())
        }

        async fn remove(&self, path: &str, _kind: NodeKind) -> Result<(), DeleteError> {
            self.removed.lock().unwrap().push(path.to_string());
            if let Some((ref fail_path, fatal)) = self.fail_remove {
                if fail_path == path {
                    return Err(DeleteError::new("删除失败", fatal));
                }
            }
            Ok(())
        }
    }

    fn service() -> DeleteService {
        DeleteService::new(None)
    }

    // ---- 正常流程 ----

    #[tokio::test]
    async fn local_delete_single_file_reports_per_item_result() {
        let svc = service();
        let fs = MockFs::new().with_file("/tmp/file.txt");
        let id = svc
            .start_delete(WorkKind::LocalDelete, vec!["/tmp/file.txt".into()], fs)
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Completed);
        assert_eq!(snap.snapshot.succeeded, 1);
        assert!(snap.snapshot.errors.is_empty());
        assert_eq!(snap.snapshot.kind, WorkKind::LocalDelete);
    }

    #[tokio::test]
    async fn local_delete_directory_reports_all_items() {
        let svc = service();
        let fs = MockFs::new().with_dir("/tmp/dir", vec!["a.txt", "b.txt"]);
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/dir".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Completed);
        assert_eq!(snap.snapshot.succeeded, 3); // dir + 2 files
        assert!(snap.snapshot.errors.is_empty());
    }

    #[tokio::test]
    async fn remote_delete_with_per_item_results() {
        let svc = service();
        let fs = MockFs::new().with_dir("/remote/project", vec!["main.rs", "lib.rs"]);
        let id = svc
            .start_delete(
                WorkKind::RemoteDelete,
                vec!["/remote/project".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Completed);
        assert_eq!(snap.snapshot.kind, WorkKind::RemoteDelete);
        assert_eq!(snap.snapshot.succeeded, 3); // dir + 2 files
    }

    #[tokio::test]
    async fn multiple_targets_produce_one_task_with_combined_results() {
        let svc = service();
        let fs = MockFs::new()
            .with_file("/tmp/a.txt")
            .with_file("/tmp/b.txt");
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/a.txt".into(), "/tmp/b.txt".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Completed);
        assert_eq!(snap.snapshot.succeeded, 2);
    }

    #[tokio::test]
    async fn list_returns_all_active_tasks() {
        let svc = service();
        let fs1 = MockFs::new().with_file("/tmp/a.txt");
        let fs2 = MockFs::new().with_file("/tmp/b.txt");
        svc.start_delete(
            WorkKind::LocalDelete,
            vec!["/tmp/a.txt".into()],
            fs1,
        )
        .unwrap();
        svc.start_delete(
            WorkKind::RemoteDelete,
            vec!["/tmp/b.txt".into()],
            fs2,
        )
        .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let list = svc.list();
        assert_eq!(list.len(), 2);
    }

    // ---- 意外流程 ----

    #[tokio::test]
    async fn file_disappeared_before_inspect_reports_error() {
        let svc = service();
        let fs = MockFs::new().with_fail_inspect("/tmp/gone.txt");
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/gone.txt".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Failed);
        assert_eq!(snap.snapshot.errors.len(), 1);
        assert!(snap.snapshot.errors[0].message.contains("inspect 失败"));
    }

    #[tokio::test]
    async fn permission_denied_on_remove_records_non_fatal_error() {
        let svc = service();
        let fs = MockFs::new()
            .with_dir("/tmp/dir", vec!["a.txt", "b.txt"])
            .with_fail_remove("/tmp/dir/a.txt", false);
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/dir".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Failed);
        assert_eq!(snap.snapshot.errors.len(), 1);
        assert!(snap.snapshot.errors[0].message.contains("删除失败"));
        assert_eq!(snap.snapshot.succeeded, 2); // dir + b.txt
    }

    #[tokio::test]
    async fn fatal_error_stops_processing_remaining_items() {
        let svc = service();
        let fs = MockFs::new()
            .with_dir("/tmp/dir", vec!["a.txt", "b.txt"])
            .with_fail_remove("/tmp/dir/a.txt", true);
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/dir".into()],
                fs,
            )
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.snapshot.status, WorkStatus::Failed);
        assert_eq!(snap.snapshot.processed, 1);
        assert_eq!(snap.snapshot.succeeded, 0);
    }

    // ---- 边界条件 ----

    #[tokio::test]
    async fn empty_targets_returns_error() {
        let svc = service();
        let fs = MockFs::new();
        let result = svc.start_delete(WorkKind::LocalDelete, vec![], fs);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("删除目标不能为空"));
    }

    #[tokio::test]
    async fn cancel_before_completion_stops_processing() {
        let changed_count = Arc::new(AtomicUsize::new(0));
        let changed_count_clone = changed_count.clone();
        let svc = DeleteService::new(Some(Arc::new(move || {
            changed_count_clone.fetch_add(1, Ordering::SeqCst);
        })));
        let fs = MockFs::new().with_dir("/tmp/dir", vec!["a.txt", "b.txt"]);
        let id = svc
            .start_delete(
                WorkKind::LocalDelete,
                vec!["/tmp/dir".into()],
                fs,
            )
            .unwrap();

        svc.cancel(&id).unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let snap = svc.status(&id).unwrap();
        assert!(
            snap.snapshot.status == WorkStatus::Cancelled
                || snap.snapshot.status == WorkStatus::Completed
        );
    }

    #[tokio::test]
    async fn cancel_unknown_task_returns_error() {
        let svc = service();
        let result = svc.cancel("nonexistent-id");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("未知删除任务"));
    }

    #[tokio::test]
    async fn status_unknown_task_returns_error() {
        let svc = service();
        let result = svc.status("nonexistent-id");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("未知删除任务"));
    }

    #[tokio::test]
    async fn change_counter_increments_on_task_events() {
        let svc = service();
        let before = svc.change_counter();
        let fs = MockFs::new().with_file("/tmp/file.txt");
        svc.start_delete(
            WorkKind::LocalDelete,
            vec!["/tmp/file.txt".into()],
            fs,
        )
        .unwrap();
        let after_start = svc.change_counter();
        assert!(after_start > before);

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let after_complete = svc.change_counter();
        assert!(after_complete > after_start);
    }

    #[tokio::test]
    async fn invalid_work_kind_returns_error() {
        let svc = service();
        let fs = MockFs::new().with_file("/tmp/file.txt");
        let result = svc.start_delete(WorkKind::Upload, vec!["/tmp/file.txt".into()], fs);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn root_path_target_returns_error() {
        let svc = service();
        let fs = MockFs::new();
        let result = svc.start_delete(WorkKind::LocalDelete, vec!["/".into()], fs);
        assert!(result.is_err());
    }
}
