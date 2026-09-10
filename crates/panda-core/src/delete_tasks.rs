//! 可观察、可取消的后序删除；扫描和删除均使用显式栈，不跟随链接。

use crate::task_summary::{WorkFailure, WorkKind, WorkSnapshot, WorkStatus};
use std::future::Future;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind { File, Directory, Symlink }

#[derive(Debug)]
pub struct DeleteError { pub message: String, pub fatal: bool }

impl DeleteError {
    pub fn new(message: impl Into<String>, fatal: bool) -> Self { Self { message: message.into(), fatal } }
}

pub trait DeleteFileSystem: Send + Sync {
    fn inspect(&self, path: &str) -> impl Future<Output = Result<NodeKind, DeleteError>> + Send;
    fn children(&self, path: &str) -> impl Future<Output = Result<Vec<String>, DeleteError>> + Send;
    fn remove(&self, path: &str, kind: NodeKind) -> impl Future<Output = Result<(), DeleteError>> + Send;
    fn close(&self) -> impl Future<Output = ()> + Send { async {} }
}

pub struct LocalDeleteFileSystem;

impl DeleteFileSystem for LocalDeleteFileSystem {
    async fn inspect(&self, path: &str) -> Result<NodeKind, DeleteError> {
        let meta = tokio::fs::symlink_metadata(path).await.map_err(local_error)?;
        Ok(if meta.is_symlink() { NodeKind::Symlink } else if meta.is_dir() { NodeKind::Directory } else { NodeKind::File })
    }
    async fn children(&self, path: &str) -> Result<Vec<String>, DeleteError> {
        let mut dir = tokio::fs::read_dir(path).await.map_err(local_error)?;
        let mut names = Vec::new();
        while let Some(entry) = dir.next_entry().await.map_err(local_error)? {
            names.push(entry.file_name().into_string().map_err(|_| DeleteError::new("文件名不是有效 UTF-8", false))?);
        }
        Ok(names)
    }
    async fn remove(&self, path: &str, kind: NodeKind) -> Result<(), DeleteError> {
        match kind {
            NodeKind::Directory => tokio::fs::remove_dir(path).await,
            NodeKind::File | NodeKind::Symlink => tokio::fs::remove_file(path).await,
        }.map_err(local_error)
    }
}

fn local_error(error: std::io::Error) -> DeleteError { DeleteError::new(error.to_string(), false) }

#[derive(Clone)]
pub struct DeleteTask {
    targets: Arc<Vec<String>>,
    snapshot: Arc<Mutex<WorkSnapshot>>,
    cancelled: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
    changed: Arc<dyn Fn() + Send + Sync>,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\\', '\0'])
}

impl DeleteTask {
    pub fn new(id: String, kind: WorkKind, targets: Vec<String>, changed: Arc<dyn Fn() + Send + Sync>) -> Result<Self, String> {
        if !matches!(kind, WorkKind::LocalDelete | WorkKind::RemoteDelete) { return Err("删除任务类型无效".into()); }
        if targets.is_empty() { return Err("删除目标不能为空".into()); }
        let mut normalized = Vec::new();
        for target in targets {
            let path = target.trim_end_matches('/');
            if !path.starts_with('/') || path.len() <= 1 || path[1..].split('/').any(|name| !valid_name(name)) {
                return Err("拒绝空目标、根目录、相对路径或越界路径".into());
            }
            normalized.push(path.to_owned());
        }
        normalized.sort(); normalized.dedup();
        let targets: Vec<_> = normalized.iter().filter(|path| !normalized.iter().any(|parent|
            *path != parent && path.starts_with(&format!("{parent}/")))).cloned().collect();
        let snapshot = WorkSnapshot::new(id, kind, WorkStatus::Scanning, targets.join("\n"));
        Ok(Self { targets: Arc::new(targets), snapshot: Arc::new(Mutex::new(snapshot)),
            cancelled: Arc::new(AtomicBool::new(false)), started: Arc::new(AtomicBool::new(false)), changed })
    }

    pub fn snapshot(&self) -> WorkSnapshot { self.snapshot.lock().unwrap().clone() }

    fn update(&self, update: impl FnOnce(&mut WorkSnapshot)) {
        update(&mut self.snapshot.lock().unwrap());
        (self.changed)();
    }

    pub fn cancel(&self) {
        let mut snapshot = self.snapshot.lock().unwrap();
        if !snapshot.status.is_unfinished() || snapshot.status == WorkStatus::Cancelling { return; }
        self.cancelled.store(true, Ordering::SeqCst);
        snapshot.status = WorkStatus::Cancelling;
        drop(snapshot); (self.changed)();
    }

    pub fn fail_to_start(&self, message: String) {
        self.update(|s| {
            s.errors.push(WorkFailure { path: s.source.clone(), message });
            s.status = if self.cancelled.load(Ordering::SeqCst) { WorkStatus::Cancelled } else { WorkStatus::Failed };
        });
    }

    /// 重复启动不重复执行；关闭并释放文件系统/连接后才发布终态。
    pub async fn run<F: DeleteFileSystem>(&self, fs: F) {
        if self.started.swap(true, Ordering::SeqCst) { fs.close().await; return; }
        self.execute(&fs).await;
        fs.close().await;
        drop(fs);
        self.update(|s| {
            s.status = if self.cancelled.load(Ordering::SeqCst) { WorkStatus::Cancelled }
                else if !s.errors.is_empty() { WorkStatus::Failed } else { WorkStatus::Completed };
        });
    }

    fn record_error(&self, path: String, error: DeleteError) {
        self.update(|s| s.errors.push(WorkFailure { path, message: error.message }));
    }

    async fn execute<F: DeleteFileSystem>(&self, fs: &F) {
        let mut stack: Vec<_> = self.targets.iter().rev().map(|path| (path.clone(), false)).collect();
        let mut plan = Vec::new();
        while let Some((path, visited)) = stack.pop() {
            if self.cancelled.load(Ordering::SeqCst) { return; }
            if visited { plan.push((path, NodeKind::Directory)); continue; }
            self.update(|s| s.current_path = Some(path.clone()));
            let kind = match fs.inspect(&path).await {
                Ok(kind) => kind,
                Err(error) => { self.record_error(path, error); return; }
            };
            self.update(|s| s.discovered += 1);
            if kind == NodeKind::Directory {
                let mut children = match fs.children(&path).await {
                    Ok(names) => names,
                    Err(error) => { self.record_error(path, error); return; }
                };
                if children.iter().any(|name| !valid_name(name)) {
                    self.record_error(path, DeleteError::new("目录包含越界名称", true)); return;
                }
                children.sort(); children.dedup();
                stack.push((path.clone(), true));
                stack.extend(children.into_iter().rev().map(|name| (format!("{path}/{name}"), false)));
            } else { plan.push((path, kind)); }
        }
        if self.cancelled.load(Ordering::SeqCst) { return; }
        self.update(|s| { s.total = Some(plan.len() as u64); if s.status != WorkStatus::Cancelling { s.status = WorkStatus::Running; } });
        for (path, kind) in plan {
            if self.cancelled.load(Ordering::SeqCst) { return; }
            self.update(|s| s.current_path = Some(path.clone()));
            let result = fs.remove(&path, kind).await;
            let fatal = result.as_ref().err().is_some_and(|error| error.fatal);
            self.update(|s| {
                s.processed += 1;
                match result {
                    Ok(()) => s.succeeded += 1,
                    Err(error) => s.errors.push(WorkFailure { path, message: error.message }),
                }
            });
            if fatal { return; }
        }
    }
}
