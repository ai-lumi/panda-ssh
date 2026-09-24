//! 单文件传输服务：任务注册表、调度、状态转换、进度修订及凭据持有。
//!
//! 核心拥有任务生命周期；实际 SSH/SFTP 传输通过 [`TransferExecutor`] 委托给调用方。

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::{Notify, Semaphore};
use uuid::Uuid;

use crate::transfer_speed::TransferSpeedTracker;
use crate::Error;

mod directories;
pub use directories::*;
#[cfg(test)]
mod directory_tests;

#[cfg(test)]
mod conflict_tests;

mod operations;
pub use operations::*;
#[cfg(test)]
mod operation_tests;
#[cfg(test)]
mod scanning_tests;

const DEFAULT_CONCURRENCY: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransferDirection {
    Upload,
    Download,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransferStatus {
    Queued,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
    Skipped,
}

impl TransferStatus {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            TransferStatus::Completed
                | TransferStatus::Failed
                | TransferStatus::Cancelled
                | TransferStatus::Skipped
        )
    }
}

#[derive(Debug, Clone)]
pub struct ConflictInfo {
    pub source_size: u64,
    pub source_mtime: Option<u64>,
    pub target_size: u64,
    pub target_mtime: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictResolution {
    Overwrite,
    Skip,
}

const CONFLICT_TIMEOUT_SECS: u64 = 300;

#[derive(Debug, Clone)]
pub struct TransferParams {
    pub direction: TransferDirection,
    pub host_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub password: Option<String>,
    pub passphrase: Option<String>,
    pub group_id: Option<String>,
    pub group_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TransferSnapshot {
    pub id: String,
    pub direction: TransferDirection,
    pub host_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub transferred: u64,
    pub status: TransferStatus,
    pub error: Option<String>,
    pub version: u64,
    pub speed: f64,
    pub total_speed: f64,
    pub eta_seconds: Option<f64>,
    pub group_id: Option<String>,
    pub group_name: Option<String>,
    pub conflict: Option<ConflictInfo>,
}

pub(super) struct ConflictResolver {
    pub(super) decision: Mutex<Option<ConflictResolution>>,
    pub(super) notify: Notify,
}

#[derive(Debug, Clone)]
pub struct TransferGroupSnapshot {
    pub group_id: String,
    pub group_name: String,
    pub direction: TransferDirection,
    pub total_count: u32,
    pub completed_count: u32,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub status: TransferStatus,
}

pub struct TransferContext {
    pub direction: TransferDirection,
    pub host_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub password: Option<String>,
    pub passphrase: Option<String>,
    pub progress: Arc<dyn Fn(u64, u64) + Send + Sync>,
    pub cancel: Arc<AtomicBool>,
    pub paused: Arc<AtomicBool>,
    pub resume_notify: Arc<Notify>,
}

pub trait TransferExecutor: Send + Sync + 'static {
    fn execute(
        &self,
        ctx: TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>>;

    fn check_conflict(
        &self,
        _ctx: &TransferContext,
    ) -> Pin<Box<dyn Future<Output = Result<Option<ConflictInfo>, String>> + Send>> {
        Box::pin(async { Ok(None) })
    }

    fn open_directory(
        &self,
        _ctx: DirectoryContext,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn DirectoryWriter>, String>> + Send>> {
        Box::pin(async { Err("目录执行器未配置".into()) })
    }
}

struct TransferTask {
    id: Uuid,
    operation_id: Option<String>,
    direction: TransferDirection,
    host_id: String,
    local_path: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    size: u64,
    status: Arc<Mutex<TransferStatus>>,
    transferred: Arc<AtomicU64>,
    error: Arc<Mutex<Option<String>>>,
    cancel: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    resume_notify: Arc<Notify>,
    version: Arc<AtomicU64>,
    speed_tracker: Arc<Mutex<TransferSpeedTracker>>,
    group_id: Option<String>,
    group_name: Option<String>,
    conflict_info: Arc<Mutex<Option<ConflictInfo>>>,
}

impl TransferTask {
    fn new(params: TransferParams, operation_id: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            operation_id,
            direction: params.direction,
            host_id: params.host_id,
            local_path: params.local_path,
            remote_path: params.remote_path,
            password: params.password,
            passphrase: params.passphrase,
            size: params.size,
            status: Arc::new(Mutex::new(TransferStatus::Queued)),
            transferred: Arc::new(AtomicU64::new(0)),
            error: Arc::new(Mutex::new(None)),
            cancel: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            resume_notify: Arc::new(Notify::new()),
            version: Arc::new(AtomicU64::new(1)),
            speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(params.size))),
            group_id: params.group_id,
            group_name: params.group_name,
            conflict_info: Arc::new(Mutex::new(None)),
        }
    }

    fn snapshot(&self) -> TransferSnapshot {
        let tracker = self.speed_tracker.lock().unwrap();
        TransferSnapshot {
            id: self.id.to_string(),
            direction: self.direction,
            host_id: self.host_id.clone(),
            local_path: self.local_path.clone(),
            remote_path: self.remote_path.clone(),
            size: self.size,
            transferred: self.transferred.load(Ordering::Relaxed),
            status: *self.status.lock().unwrap(),
            error: self.error.lock().unwrap().clone(),
            version: self.version.load(Ordering::Relaxed),
            speed: tracker.live_speed(),
            total_speed: tracker.total_speed(),
            eta_seconds: tracker.eta_seconds(),
            group_id: self.group_id.clone(),
            group_name: self.group_name.clone(),
            conflict: self.conflict_info.lock().unwrap().clone(),
        }
    }

    fn progress_callback(&self) -> Arc<dyn Fn(u64, u64) + Send + Sync> {
        let task = self.clone_ref();
        Arc::new(move |done, _total| {
            task.transferred.store(done, Ordering::Relaxed);
            task.speed_tracker.lock().unwrap().update(done);
            task.bump_version();
        })
    }

    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }

    fn clone_ref(&self) -> TransferTaskRef {
        TransferTaskRef {
            transferred: self.transferred.clone(),
            speed_tracker: self.speed_tracker.clone(),
            version: self.version.clone(),
        }
    }
}

struct TransferTaskRef {
    transferred: Arc<AtomicU64>,
    speed_tracker: Arc<Mutex<TransferSpeedTracker>>,
    version: Arc<AtomicU64>,
}

impl TransferTaskRef {
    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }
}

struct ServiceInner {
    registry: Mutex<operations::TransferRegistry>,
    semaphore: Semaphore,
    executor: Box<dyn TransferExecutor>,
    change_counter: AtomicU64,
    on_change: Option<Arc<dyn Fn() + Send + Sync>>,
    conflict_timeout_secs: u64,
    target_locks: Mutex<std::collections::HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl ServiceInner {
    fn notify_changed(&self) {
        self.bump_revision();
        self.emit_changed();
    }

    fn bump_revision(&self) {
        self.change_counter.fetch_add(1, Ordering::Relaxed);
    }

    fn emit_changed(&self) {
        if let Some(ref cb) = self.on_change {
            cb();
        }
    }
}

pub struct TransferService {
    inner: Arc<ServiceInner>,
}

impl Clone for TransferService {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl TransferService {
    pub fn new(executor: Box<dyn TransferExecutor>) -> Self {
        Self::with_concurrency(executor, DEFAULT_CONCURRENCY, None)
    }

    pub fn with_concurrency(
        executor: Box<dyn TransferExecutor>,
        concurrency: usize,
        on_change: Option<Arc<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::with_concurrency_and_conflict_timeout(
            executor,
            concurrency,
            on_change,
            CONFLICT_TIMEOUT_SECS,
        )
    }

    pub fn with_concurrency_and_conflict_timeout(
        executor: Box<dyn TransferExecutor>,
        concurrency: usize,
        on_change: Option<Arc<dyn Fn() + Send + Sync>>,
        conflict_timeout_secs: u64,
    ) -> Self {
        Self {
            inner: Arc::new(ServiceInner {
                registry: Mutex::new(operations::TransferRegistry::default()),
                semaphore: Semaphore::new(concurrency),
                executor,
                change_counter: AtomicU64::new(0),
                on_change,
                conflict_timeout_secs,
                target_locks: Mutex::new(std::collections::HashMap::new()),
            }),
        }
    }

    pub fn start_transfer(&self, params: TransferParams) -> Result<String, Error> {
        let mut registry = self.inner.registry.lock().unwrap();
        registry.ensure_accepting()?;
        let task = Arc::new(TransferTask::new(params, None));
        let id = task.id;
        registry.tasks.insert(id, task.clone());
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();

        let inner = self.inner.clone();
        tokio::spawn(async move {
            run_transfer_task(inner, task).await;
        });
        Ok(id.to_string())
    }

    pub fn transfer_status(&self, task_id: &str) -> Result<TransferSnapshot, Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let task = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        Ok(task.snapshot())
    }

    pub fn transfer_list(&self) -> Vec<TransferSnapshot> {
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let mut snapshots: Vec<_> = tasks.values().map(|t| t.snapshot()).collect();
        snapshots.sort_by(|a, b| a.id.cmp(&b.id));
        snapshots
    }

    pub fn transfer_groups(&self) -> Vec<TransferGroupSnapshot> {
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let mut groups: HashMap<
            String,
            (
                String,
                TransferDirection,
                Vec<TransferStatus>,
                u64,
                u64,
                u32,
            ),
        > = HashMap::new();

        for task in tasks.values() {
            if let (Some(gid), Some(gname)) = (&task.group_id, &task.group_name) {
                let entry = groups
                    .entry(gid.clone())
                    .or_insert_with(|| (gname.clone(), task.direction, Vec::new(), 0, 0, 0));
                let status = *task.status.lock().unwrap();
                entry.2.push(status);
                entry.3 += task.size;
                entry.4 += task.transferred.load(Ordering::Relaxed);
                entry.5 += 1;
            }
        }

        let mut result: Vec<TransferGroupSnapshot> = groups
            .into_iter()
            .map(
                |(gid, (gname, dir, statuses, total_bytes, transferred_bytes, total_count))| {
                    let completed_count =
                        statuses.iter().filter(|s| s.is_terminal()).count() as u32;
                    TransferGroupSnapshot {
                        group_id: gid,
                        group_name: gname,
                        direction: dir,
                        total_count,
                        completed_count,
                        total_bytes,
                        transferred_bytes,
                        status: group_status_priority(&statuses),
                    }
                },
            )
            .collect();
        result.sort_by(|a, b| a.group_name.cmp(&b.group_name));
        result
    }

    pub fn transfer_cancel(&self, task_id: &str) -> Result<(), Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let task = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        task.cancel.store(true, Ordering::Relaxed);
        task.resume_notify.notify_waiters();
        let status = *task.status.lock().unwrap();
        if matches!(status, TransferStatus::Queued | TransferStatus::Paused) {
            *task.status.lock().unwrap() = TransferStatus::Cancelled;
            task.bump_version();
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
        }
        Ok(())
    }

    pub fn transfer_retry(&self, task_id: &str) -> Result<String, Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let mut registry = self.inner.registry.lock().unwrap();
        registry.ensure_accepting()?;
        let task = registry
            .tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?
            .clone();

        {
            let status = *task.status.lock().unwrap();
            if !matches!(
                status,
                TransferStatus::Failed | TransferStatus::Cancelled | TransferStatus::Skipped
            ) {
                return Err(Error::Other("任务不在可重试状态".into()));
            }
        }

        *task.status.lock().unwrap() = TransferStatus::Queued;
        task.transferred.store(0, Ordering::Relaxed);
        *task.error.lock().unwrap() = None;
        task.cancel.store(false, Ordering::Relaxed);
        task.paused.store(false, Ordering::Relaxed);
        *task.speed_tracker.lock().unwrap() = TransferSpeedTracker::new(task.size);
        task.resume_notify.notify_waiters();
        task.bump_version();

        let mut rerun_preparation = false;
        let mut new_run: Option<Arc<directories::DirectoryRun>> = None;
        let mut group_id_for_prep: Option<String> = None;
        if let Some(ref gid) = task.group_id {
            if let Some(group) = registry.groups.get_mut(gid) {
                if matches!(
                    group.snapshot.status,
                    TransferStatus::Failed | TransferStatus::Cancelled | TransferStatus::Skipped
                ) {
                    group.snapshot.status = TransferStatus::Queued;
                    group.snapshot.error = None;
                    for directory in &mut group.snapshot.directories {
                        directory.status = TransferStatus::Queued;
                        directory.error = None;
                    }
                    let run = Arc::new(directories::DirectoryRun::default());
                    group.run = run.clone();
                    new_run = Some(run);
                    rerun_preparation = true;
                    group_id_for_prep = Some(gid.clone());
                }
            }
        }

        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();

        if let Some(run) = new_run {
            tokio::spawn(directories::run_preparation(
                self.inner.clone(),
                group_id_for_prep.unwrap(),
                run,
            ));
        }
        if !rerun_preparation {
            let inner = self.inner.clone();
            tokio::spawn(async move {
                run_transfer_task(inner, task).await;
            });
        }
        Ok(id.to_string())
    }

    pub fn transfer_pause(&self, task_id: &str) -> Result<(), Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let task = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        let status = *task.status.lock().unwrap();
        if status.is_terminal() {
            return Err(Error::Other("任务已终态".into()));
        }
        task.paused.store(true, Ordering::Relaxed);
        task.speed_tracker.lock().unwrap().on_pause();
        if matches!(status, TransferStatus::Queued | TransferStatus::Running) {
            *task.status.lock().unwrap() = TransferStatus::Paused;
            task.bump_version();
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
        }
        Ok(())
    }

    pub fn transfer_resume(&self, task_id: &str) -> Result<(), Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let task = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        task.paused.store(false, Ordering::Relaxed);
        task.speed_tracker.lock().unwrap().on_resume();
        task.resume_notify.notify_waiters();
        let status = *task.status.lock().unwrap();
        if status == TransferStatus::Paused {
            *task.status.lock().unwrap() = TransferStatus::Queued;
            task.bump_version();
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
        }
        Ok(())
    }

    pub fn group_cancel(&self, group_id: &str) -> Result<(), Error> {
        let mut registry = self.inner.registry.lock().unwrap();
        let mut found = false;
        if let Some(group) = registry.groups.get_mut(group_id) {
            found = true;
            group.cancel();
        }
        for task in registry.tasks.values() {
            if task.group_id.as_deref() == Some(group_id) {
                found = true;
                let status = *task.status.lock().unwrap();
                if !status.is_terminal() {
                    task.cancel.store(true, Ordering::Relaxed);
                    task.resume_notify.notify_waiters();
                    if matches!(status, TransferStatus::Queued | TransferStatus::Paused) {
                        *task.status.lock().unwrap() = TransferStatus::Cancelled;
                        task.bump_version();
                    }
                }
            }
        }
        if found {
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
            Ok(())
        } else {
            Err(Error::Other(format!("未知组: {group_id}")))
        }
    }

    pub fn group_pause(&self, group_id: &str) -> Result<(), Error> {
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let mut found = false;
        for task in tasks.values() {
            if task.group_id.as_deref() == Some(group_id) {
                found = true;
                let status = *task.status.lock().unwrap();
                if !status.is_terminal() && !matches!(status, TransferStatus::Paused) {
                    task.paused.store(true, Ordering::Relaxed);
                    task.speed_tracker.lock().unwrap().on_pause();
                    if matches!(status, TransferStatus::Queued | TransferStatus::Running) {
                        *task.status.lock().unwrap() = TransferStatus::Paused;
                        task.bump_version();
                    }
                }
            }
        }
        if found {
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
            Ok(())
        } else {
            Err(Error::Other(format!("未知组: {group_id}")))
        }
    }

    pub fn group_resume(&self, group_id: &str) -> Result<(), Error> {
        let registry = self.inner.registry.lock().unwrap();
        let tasks = &registry.tasks;
        let mut found = false;
        for task in tasks.values() {
            if task.group_id.as_deref() == Some(group_id) {
                found = true;
                let status = *task.status.lock().unwrap();
                if status == TransferStatus::Paused {
                    task.paused.store(false, Ordering::Relaxed);
                    task.speed_tracker.lock().unwrap().on_resume();
                    *task.status.lock().unwrap() = TransferStatus::Queued;
                    task.bump_version();
                    task.resume_notify.notify_waiters();
                }
            }
        }
        if found {
            self.inner.bump_revision();
            drop(registry);
            self.inner.emit_changed();
            Ok(())
        } else {
            Err(Error::Other(format!("未知组: {group_id}")))
        }
    }

    pub fn group_retry(&self, group_id: &str) -> Result<(), Error> {
        let mut registry = self.inner.registry.lock().unwrap();
        registry.ensure_accepting()?;
        let tasks = &registry.tasks;
        let mut found = false;
        let mut to_retry: Vec<Arc<TransferTask>> = Vec::new();
        for task in tasks.values() {
            if task.group_id.as_deref() == Some(group_id) {
                found = true;
                let status = *task.status.lock().unwrap();
                if matches!(status, TransferStatus::Failed | TransferStatus::Cancelled | TransferStatus::Skipped) {
                    to_retry.push(task.clone());
                }
            }
        }
        if !found {
            return Err(Error::Other(format!("未知组: {group_id}")));
        }
        let mut rerun_preparation = false;
        let mut new_run: Option<Arc<directories::DirectoryRun>> = None;
        if let Some(group) = registry.groups.get_mut(group_id) {
            if matches!(
                group.snapshot.status,
                TransferStatus::Failed | TransferStatus::Cancelled | TransferStatus::Skipped
            ) {
                group.snapshot.status = TransferStatus::Queued;
                group.snapshot.error = None;
                for directory in &mut group.snapshot.directories {
                    directory.status = TransferStatus::Queued;
                    directory.error = None;
                }
                let run = Arc::new(directories::DirectoryRun::default());
                group.run = run.clone();
                new_run = Some(run);
                rerun_preparation = true;
            }
        }
        for task in to_retry {
            *task.status.lock().unwrap() = TransferStatus::Queued;
            task.transferred.store(0, Ordering::Relaxed);
            *task.error.lock().unwrap() = None;
            task.cancel.store(false, Ordering::Relaxed);
            task.paused.store(false, Ordering::Relaxed);
            *task.speed_tracker.lock().unwrap() = TransferSpeedTracker::new(task.size);
            task.resume_notify.notify_waiters();
            task.bump_version();
            if !rerun_preparation {
                let inner = self.inner.clone();
                let task_clone = task.clone();
                tokio::spawn(async move {
                    run_transfer_task(inner, task_clone).await;
                });
            }
        }
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();
        if let Some(run) = new_run {
            tokio::spawn(directories::run_preparation(
                self.inner.clone(),
                group_id.to_string(),
                run,
            ));
        }
        Ok(())
    }

    pub fn change_counter(&self) -> u64 {
        self.inner.change_counter.load(Ordering::Relaxed)
    }

    pub fn resolve_conflict(&self, task_id: &str, overwrite: bool) -> Result<bool, Error> {
        let id = Uuid::parse_str(task_id).map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let resolution = if overwrite {
            ConflictResolution::Overwrite
        } else {
            ConflictResolution::Skip
        };
        let registry = self.inner.registry.lock().unwrap();
        if !registry.tasks.contains_key(&id) {
            return Err(Error::Other(format!("未知任务: {task_id}")));
        }
        if let Some(resolver) = registry.pending_conflicts.get(&id) {
            *resolver.decision.lock().unwrap() = Some(resolution);
            resolver.notify.notify_waiters();
            Ok(true)
        } else {
            Ok(false)
        }
    }
}

async fn wait_for_cancel(task: &TransferTask) {
    loop {
        let notified = task.resume_notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if task.cancel.load(Ordering::Acquire) {
            return;
        }
        notified.await;
    }
}

async fn wait_while_paused(task: &Arc<TransferTask>) {
    loop {
        if task.cancel.load(Ordering::Relaxed) {
            return;
        }
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        {
            let mut status = task.status.lock().unwrap();
            if *status == TransferStatus::Cancelled {
                return;
            }
            *status = TransferStatus::Paused;
            drop(status);
        }
        let notified = task.resume_notify.notified();
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        notified.await;
    }
}

async fn run_transfer_task(inner: Arc<ServiceInner>, task: Arc<TransferTask>) {
    {
        let registry = inner.registry.lock().unwrap();
        if !registry.accepting {
            return;
        }
        if let Some(group) = task
            .group_id
            .as_ref()
            .and_then(|id| registry.groups.get(id))
        {
            if !group.files_ready() || group.dependency_error(&task).is_some() {
                return;
            }
        }
    }
    wait_while_paused(&task).await;
    if task.cancel.load(Ordering::Relaxed) {
        *task.status.lock().unwrap() = TransferStatus::Cancelled;
        inner.notify_changed();
        return;
    }

    let target_key = {
        let target_path = match task.direction {
            TransferDirection::Upload => task.remote_path.clone(),
            TransferDirection::Download => task.local_path.clone(),
        };
        format!("{}:{:?}:{}", task.host_id, task.direction, target_path)
    };
    let target_mutex = {
        let mut locks = inner.target_locks.lock().unwrap();
        locks
            .entry(target_key)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    };
    let _target_guard = target_mutex.lock().await;

    wait_while_paused(&task).await;
    if task.cancel.load(Ordering::Relaxed) {
        *task.status.lock().unwrap() = TransferStatus::Cancelled;
        inner.notify_changed();
        return;
    }

    {
        let registry = inner.registry.lock().unwrap();
        let mut status = task.status.lock().unwrap();
        if !registry.accepting
            || task.cancel.load(Ordering::Acquire)
            || *status == TransferStatus::Cancelled
        {
            return;
        }
        *status = TransferStatus::Running;
        task.bump_version();
        inner.bump_revision();
    }
    inner.emit_changed();

    let ctx = TransferContext {
        direction: task.direction,
        host_id: task.host_id.clone(),
        local_path: task.local_path.clone(),
        remote_path: task.remote_path.clone(),
        password: task.password.clone(),
        passphrase: task.passphrase.clone(),
        progress: task.progress_callback(),
        cancel: task.cancel.clone(),
        paused: task.paused.clone(),
        resume_notify: task.resume_notify.clone(),
    };

    let conflict_result = tokio::select! {
        biased;
        _ = wait_for_cancel(&task) => None,
        result = inner.executor.check_conflict(&ctx) => Some(result),
    };

    if task.cancel.load(Ordering::Acquire) {
        *task.status.lock().unwrap() = TransferStatus::Cancelled;
        task.bump_version();
        inner.notify_changed();
        return;
    }

    let conflict_result = match conflict_result {
        Some(r) => r,
        None => {
            *task.status.lock().unwrap() = TransferStatus::Cancelled;
            task.bump_version();
            inner.notify_changed();
            return;
        }
    };

    match conflict_result {
        Err(e) => {
            *task.status.lock().unwrap() = TransferStatus::Failed;
            *task.error.lock().unwrap() = Some(format!(
                "{} → {}: {e}",
                if task.direction == TransferDirection::Upload { &task.local_path } else { &task.remote_path },
                if task.direction == TransferDirection::Upload { &task.remote_path } else { &task.local_path },
            ));
            task.bump_version();
            inner.notify_changed();
            return;
        }
        Ok(Some(info)) => {
            *task.conflict_info.lock().unwrap() = Some(info);
            let resolver = Arc::new(ConflictResolver {
                decision: Mutex::new(None),
                notify: Notify::new(),
            });
            {
                let mut registry = inner.registry.lock().unwrap();
                registry.pending_conflicts.insert(task.id, resolver.clone());
                task.bump_version();
                inner.bump_revision();
            }
            inner.emit_changed();

            let timeout = std::time::Duration::from_secs(inner.conflict_timeout_secs);
            let decision: Option<ConflictResolution> = tokio::select! {
                biased;
                _ = wait_for_cancel(&task) => None,
                decision = async {
                    loop {
                        if let Some(d) = resolver.decision.lock().unwrap().take() {
                            break Some(d);
                        }
                        let notified = resolver.notify.notified();
                        tokio::pin!(notified);
                        notified.as_mut().enable();
                        if resolver.decision.lock().unwrap().is_some() {
                            break resolver.decision.lock().unwrap().take();
                        }
                        notified.await;
                    }
                } => decision,
                _ = tokio::time::sleep(timeout) => Some(ConflictResolution::Skip),
            };

            {
                let mut registry = inner.registry.lock().unwrap();
                registry.pending_conflicts.remove(&task.id);
            }
            *task.conflict_info.lock().unwrap() = None;

            if task.cancel.load(Ordering::Acquire) {
                *task.status.lock().unwrap() = TransferStatus::Cancelled;
                task.bump_version();
                inner.notify_changed();
                return;
            }

            match decision {
                Some(ConflictResolution::Overwrite) => {}
                _ => {
                    *task.status.lock().unwrap() = TransferStatus::Skipped;
                    task.bump_version();
                    inner.notify_changed();
                    return;
                }
            }
        }
        Ok(None) => {}
    }

    wait_while_paused(&task).await;

    let _permit = match inner.semaphore.acquire().await {
        Ok(p) => p,
        Err(_) => {
            *task.status.lock().unwrap() = TransferStatus::Failed;
            *task.error.lock().unwrap() = Some("semaphore closed".into());
            inner.notify_changed();
            return;
        }
    };

    wait_while_paused(&task).await;

    let result = tokio::select! {
        biased;
        _ = wait_for_cancel(&task) => Err("传输已取消".into()),
        result = async { inner.executor.execute(ctx).await } => result,
    };

    if task.cancel.load(Ordering::Acquire) {
        *task.status.lock().unwrap() = TransferStatus::Cancelled;
        task.bump_version();
        inner.notify_changed();
        return;
    }
    match result {
        Ok(()) => {
            *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatus::Completed;
            if task.direction == TransferDirection::Upload {
                task.transferred.store(task.size, Ordering::Relaxed);
            }
            task.bump_version();
            inner.notify_changed();
        }
        Err(e) => {
            if task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatus::Cancelled;
            } else {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatus::Failed;
                *task.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(format!(
                    "{} → {}: {e}",
                    if task.direction == TransferDirection::Upload { &task.local_path } else { &task.remote_path },
                    if task.direction == TransferDirection::Upload { &task.remote_path } else { &task.local_path },
                ));
            }
            task.bump_version();
            inner.notify_changed();
        }
    }
}

fn group_status_priority(statuses: &[TransferStatus]) -> TransferStatus {
    let set: std::collections::HashSet<_> = statuses.iter().copied().collect();
    if set.contains(&TransferStatus::Running) {
        TransferStatus::Running
    } else if set.contains(&TransferStatus::Paused) {
        TransferStatus::Paused
    } else if set.contains(&TransferStatus::Queued) {
        TransferStatus::Queued
    } else if set.contains(&TransferStatus::Failed) {
        TransferStatus::Failed
    } else if set.contains(&TransferStatus::Cancelled) {
        TransferStatus::Cancelled
    } else if set.contains(&TransferStatus::Skipped) {
        TransferStatus::Skipped
    } else {
        TransferStatus::Completed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    struct FakeExecutor {
        behavior: Arc<
            dyn Fn(TransferContext) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>>
                + Send
                + Sync,
        >,
    }

    impl FakeExecutor {
        fn success() -> Self {
            Self {
                behavior: Arc::new(|ctx| {
                    Box::pin(async move {
                        (ctx.progress)(100, 100);
                        Ok(())
                    })
                }),
            }
        }

        fn failure(msg: &'static str) -> Self {
            Self {
                behavior: Arc::new(move |ctx| {
                    let msg = msg.to_string();
                    Box::pin(async move {
                        let _ = (ctx.progress)(0, 0);
                        Err(msg)
                    })
                }),
            }
        }

        fn slow(total: u64, step: u64, delay_ms: u64) -> Self {
            Self {
                behavior: Arc::new(move |ctx| {
                    Box::pin(async move {
                        let mut done = 0u64;
                        while done < total {
                            if ctx.cancel.load(Ordering::Relaxed) {
                                return Err("cancelled".into());
                            }
                            while ctx.paused.load(Ordering::Relaxed) {
                                if ctx.cancel.load(Ordering::Relaxed) {
                                    return Err("cancelled".into());
                                }
                                let notified = ctx.resume_notify.notified();
                                if !ctx.paused.load(Ordering::Relaxed) {
                                    break;
                                }
                                notified.await;
                            }
                            done = (done + step).min(total);
                            (ctx.progress)(done, total);
                            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                        }
                        Ok(())
                    })
                }),
            }
        }

        fn custom(
            f: impl Fn(TransferContext) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>>
                + Send
                + Sync
                + 'static,
        ) -> Self {
            Self {
                behavior: Arc::new(f),
            }
        }
    }

    impl TransferExecutor for FakeExecutor {
        fn execute(
            &self,
            ctx: TransferContext,
        ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
            (self.behavior)(ctx)
        }
    }

    fn upload_params(size: u64) -> TransferParams {
        TransferParams {
            direction: TransferDirection::Upload,
            host_id: "host-1".into(),
            local_path: "/local/file".into(),
            remote_path: "/remote/file".into(),
            size,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        }
    }

    fn download_params(size: u64) -> TransferParams {
        TransferParams {
            direction: TransferDirection::Download,
            host_id: "host-1".into(),
            local_path: "/local/file".into(),
            remote_path: "/remote/file".into(),
            size,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        }
    }

    async fn wait_for_status(service: &TransferService, id: &str, expected: TransferStatus) {
        for _ in 0..100 {
            let snap = service.transfer_status(id).unwrap();
            if snap.status == expected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!(
            "task {id} did not reach {expected:?} in time, current: {:?}",
            service.transfer_status(id).unwrap().status
        );
    }

    async fn until(mut condition: impl FnMut() -> bool) {
        for _ in 0..200 {
            if condition() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("condition not met in time");
    }

    // --- 正常流程 ---

    #[tokio::test]
    async fn enqueue_and_complete_upload() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.transferred, 100);
        assert!(snap.error.is_none());
    }

    #[tokio::test]
    async fn enqueue_and_complete_download() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(download_params(200)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.transferred, 100);
    }

    #[tokio::test]
    async fn concurrency_limit_of_three() {
        let concurrent = Arc::new(AtomicUsize::new(0));
        let max_concurrent = Arc::new(AtomicUsize::new(0));

        let concurrent_clone = concurrent.clone();
        let max_clone = max_concurrent.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let concurrent = concurrent_clone.clone();
            let max_concurrent = max_clone.clone();
            Box::pin(async move {
                let cur = concurrent.fetch_add(1, Ordering::Relaxed) + 1;
                loop {
                    let prev_max = max_concurrent.load(Ordering::Relaxed);
                    if cur > prev_max {
                        max_concurrent.store(cur, Ordering::Relaxed);
                    } else {
                        break;
                    }
                    break;
                }
                (ctx.progress)(50, 50);
                tokio::time::sleep(Duration::from_millis(50)).await;
                concurrent.fetch_sub(1, Ordering::Relaxed);
                Ok(())
            })
        });

        let service = TransferService::with_concurrency(Box::new(executor), 3, None);
        let mut ids = Vec::new();
        for _ in 0..6 {
            ids.push(service.start_transfer(upload_params(50)).unwrap());
        }

        for id in &ids {
            wait_for_status(&service, id, TransferStatus::Completed).await;
        }

        let max = max_concurrent.load(Ordering::Relaxed);
        assert!(max <= 3, "并发上限应为 3，实际峰值: {max}");
    }

    #[tokio::test]
    async fn progress_updates_transferred_and_version() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(1000, 100, 5)));
        let id = service.start_transfer(upload_params(1000)).unwrap();

        let mut last_version = 0u64;
        for _ in 0..50 {
            let snap = service.transfer_status(&id).unwrap();
            if snap.status == TransferStatus::Completed {
                break;
            }
            if snap.transferred > 0 {
                assert!(snap.version > last_version || last_version == 0);
                last_version = snap.version;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        wait_for_status(&service, &id, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn pause_and_resume_running_task() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(100, 10, 20)));
        let id = service.start_transfer(upload_params(100)).unwrap();

        wait_for_status(&service, &id, TransferStatus::Running).await;

        service.transfer_pause(&id).unwrap();
        wait_for_status(&service, &id, TransferStatus::Paused).await;

        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.status, TransferStatus::Paused);

        service.transfer_resume(&id).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn retry_reuses_same_id() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |_ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                if n == 0 {
                    Err("first attempt fails".into())
                } else {
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Failed).await;

        let retried_id = service.transfer_retry(&id).unwrap();
        assert_eq!(retried_id, id, "重试必须复用原 id");

        wait_for_status(&service, &id, TransferStatus::Completed).await;
        assert_eq!(attempt.load(Ordering::Relaxed), 2);
    }

    // --- 意外场景 ---

    #[tokio::test]
    async fn connection_failure_sets_failed_with_error() {
        let service = TransferService::new(Box::new(FakeExecutor::failure("connection refused")));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Failed).await;
        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.error.as_deref(), Some("/local/file → /remote/file: connection refused"));
    }

    #[tokio::test]
    async fn cancel_terminal_task_is_noop() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        service.transfer_cancel(&id).unwrap();
        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.status, TransferStatus::Completed);
    }

    #[tokio::test]
    async fn retry_non_retryable_state_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let result = service.transfer_retry(&id);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn pause_terminal_task_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let result = service.transfer_pause(&id);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn unknown_task_id_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        assert!(service.transfer_status("nonexistent").is_err());
        assert!(service.transfer_cancel("nonexistent").is_err());
        assert!(service.transfer_pause("nonexistent").is_err());
        assert!(service.transfer_resume("nonexistent").is_err());
        assert!(service.transfer_retry("nonexistent").is_err());
    }

    // --- 边界场景 ---

    #[tokio::test]
    async fn queued_pause_does_not_acquire_semaphore() {
        let concurrent = Arc::new(AtomicUsize::new(0));
        let concurrent_clone = concurrent.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let concurrent = concurrent_clone.clone();
            Box::pin(async move {
                concurrent.fetch_add(1, Ordering::Relaxed);
                (ctx.progress)(10, 10);
                tokio::time::sleep(Duration::from_millis(100)).await;
                concurrent.fetch_sub(1, Ordering::Relaxed);
                Ok(())
            })
        });

        let service = TransferService::with_concurrency(Box::new(executor), 1, None);

        let id1 = service.start_transfer(upload_params(10)).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        let id2 = service.start_transfer(upload_params(10)).unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        let snap2 = service.transfer_status(&id2).unwrap();
        assert_eq!(snap2.status, TransferStatus::Queued);

        service.transfer_pause(&id2).unwrap();
        let snap2 = service.transfer_status(&id2).unwrap();
        assert_eq!(snap2.status, TransferStatus::Paused);

        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        assert_eq!(concurrent.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn running_pause_holds_semaphore_slot() {
        let service =
            TransferService::with_concurrency(Box::new(FakeExecutor::slow(100, 10, 20)), 1, None);

        let id1 = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        let id2 = service.start_transfer(upload_params(100)).unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert_eq!(
            service.transfer_status(&id2).unwrap().status,
            TransferStatus::Queued
        );

        service.transfer_pause(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Paused).await;

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(
            service.transfer_status(&id2).unwrap().status,
            TransferStatus::Queued,
            "运行中暂停应占槽，排队任务不应启动"
        );

        service.transfer_resume(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn zero_byte_task_completes_immediately() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let id = service.start_transfer(upload_params(0)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.size, 0);
    }

    #[tokio::test]
    async fn cancel_during_execution_sets_cancelled() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(10000, 100, 50)));
        let id = service.start_transfer(upload_params(10000)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Running).await;

        service.transfer_cancel(&id).unwrap();
        wait_for_status(&service, &id, TransferStatus::Cancelled).await;
    }

    #[tokio::test]
    async fn cancel_queued_task_sets_cancelled_immediately() {
        let service = TransferService::with_concurrency(
            Box::new(FakeExecutor::slow(10000, 100, 100)),
            1,
            None,
        );

        let id1 = service.start_transfer(upload_params(10000)).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        let id2 = service.start_transfer(upload_params(10000)).unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;

        service.transfer_cancel(&id2).unwrap();
        let snap = service.transfer_status(&id2).unwrap();
        assert_eq!(snap.status, TransferStatus::Cancelled);
    }

    #[tokio::test]
    async fn transfer_list_returns_all_tasks_sorted() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(100, 10, 5)));
        let mut ids = Vec::new();
        for _ in 0..3 {
            ids.push(service.start_transfer(upload_params(100)).unwrap());
        }

        let list = service.transfer_list();
        assert_eq!(list.len(), 3);
        for i in 1..list.len() {
            assert!(list[i - 1].id <= list[i].id);
        }

        for id in &ids {
            wait_for_status(&service, id, TransferStatus::Completed).await;
        }
    }

    #[tokio::test]
    async fn transfer_groups_aggregates_by_group_id() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(100, 50, 5)));

        let mut p1 = upload_params(100);
        p1.group_id = Some("g1".into());
        p1.group_name = Some("组一".into());
        let mut p2 = upload_params(200);
        p2.group_id = Some("g1".into());
        p2.group_name = Some("组一".into());

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();

        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;

        let groups = service.transfer_groups();
        assert_eq!(groups.len(), 1);
        let g = &groups[0];
        assert_eq!(g.group_id, "g1");
        assert_eq!(g.total_count, 2);
        assert_eq!(g.completed_count, 2);
        assert_eq!(g.total_bytes, 300);
        assert_eq!(g.status, TransferStatus::Completed);
    }

    #[tokio::test]
    async fn change_counter_increments_on_state_change() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let before = service.change_counter();
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;
        let after = service.change_counter();
        assert!(
            after > before,
            "变更计数器应递增: before={before}, after={after}"
        );
    }

    #[tokio::test]
    async fn retry_resets_transferred_and_error() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                if n == 0 {
                    (ctx.progress)(50, 100);
                    Err("fail".into())
                } else {
                    (ctx.progress)(100, 100);
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let id = service.start_transfer(upload_params(100)).unwrap();
        wait_for_status(&service, &id, TransferStatus::Failed).await;

        let snap = service.transfer_status(&id).unwrap();
        assert_eq!(snap.transferred, 50);
        assert!(snap.error.is_some());

        service.transfer_retry(&id).unwrap();
        wait_for_status(&service, &id, TransferStatus::Completed).await;

        let snap = service.transfer_status(&id).unwrap();
        assert!(snap.error.is_none());
    }

    // --- 7.3 组级控制 ---

    fn grouped_params(group_id: &str, group_name: &str, size: u64) -> TransferParams {
        TransferParams {
            direction: TransferDirection::Upload,
            host_id: "host-1".into(),
            local_path: "/local/file".into(),
            remote_path: "/remote/file".into(),
            size,
            password: None,
            passphrase: None,
            group_id: Some(group_id.into()),
            group_name: Some(group_name.into()),
        }
    }

    #[tokio::test]
    async fn group_cancel_cancels_all_non_terminal() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(10000, 100, 50)));
        let mut p1 = grouped_params("g1", "组一", 10000);
        p1.local_path = "/local/f1".into();
        let mut p2 = grouped_params("g1", "组一", 10000);
        p2.local_path = "/local/f2".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        service.group_cancel("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Cancelled).await;
        wait_for_status(&service, &id2, TransferStatus::Cancelled).await;
    }

    #[tokio::test]
    async fn group_cancel_unknown_group_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        assert!(service.group_cancel("nonexistent").is_err());
    }

    #[tokio::test]
    async fn group_pause_and_resume() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(100, 10, 20)));
        let mut p1 = grouped_params("g1", "组一", 100);
        p1.local_path = "/local/f1".into();
        p1.remote_path = "/remote/f1".into();
        let mut p2 = grouped_params("g1", "组一", 100);
        p2.local_path = "/local/f2".into();
        p2.remote_path = "/remote/f2".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;
        wait_for_status(&service, &id2, TransferStatus::Running).await;

        service.group_pause("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Paused).await;
        wait_for_status(&service, &id2, TransferStatus::Paused).await;

        service.group_resume("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn group_pause_unknown_group_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        assert!(service.group_pause("nonexistent").is_err());
    }

    #[tokio::test]
    async fn group_resume_unknown_group_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        assert!(service.group_resume("nonexistent").is_err());
    }

    #[tokio::test]
    async fn group_retry_retries_failed_tasks() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                if n < 2 {
                    Err("fail".into())
                } else {
                    (ctx.progress)(100, 100);
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let mut p1 = grouped_params("g1", "组一", 100);
        p1.local_path = "/local/f1".into();
        let mut p2 = grouped_params("g1", "组一", 100);
        p2.local_path = "/local/f2".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Failed).await;
        wait_for_status(&service, &id2, TransferStatus::Failed).await;

        service.group_retry("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn group_retry_unknown_group_returns_error() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        assert!(service.group_retry("nonexistent").is_err());
    }

    #[tokio::test]
    async fn group_cancel_skips_terminal_tasks() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let mut p1 = grouped_params("g1", "组一", 100);
        p1.local_path = "/local/f1".into();
        let mut p2 = grouped_params("g1", "组一", 100);
        p2.local_path = "/local/f2".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;

        service.group_cancel("g1").unwrap();
        assert_eq!(
            service.transfer_status(&id1).unwrap().status,
            TransferStatus::Completed
        );
        assert_eq!(
            service.transfer_status(&id2).unwrap().status,
            TransferStatus::Completed
        );
    }

    #[tokio::test]
    async fn empty_group_returns_ok_but_no_tasks_affected() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let p1 = grouped_params("g1", "组一", 100);
        let _id = service.start_transfer(p1).unwrap();
        // g2 不存在
        assert!(service.group_cancel("g2").is_err());
    }

    #[tokio::test]
    async fn group_retry_skips_non_failed_tasks() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(100, 50, 5)));
        let mut p1 = grouped_params("g1", "组一", 100);
        p1.local_path = "/local/f1".into();
        let mut p2 = grouped_params("g1", "组一", 100);
        p2.local_path = "/local/f2".into();

        let id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;

        // id2 可能还在运行，group_retry 只重试终态的
        // 等 id2 也完成
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        // group_retry 不应影响已完成的任务
        service.group_retry("g1").unwrap();
        // 两个都已完成，无需重试
        let snap1 = service.transfer_status(&id1).unwrap();
        assert_eq!(snap1.status, TransferStatus::Completed);
    }

    // --- 7.3 边界场景 ---

    #[tokio::test]
    async fn group_aggregation_with_mixed_terminal_states() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                match n {
                    0 => {
                        (ctx.progress)(100, 100);
                        Ok(())
                    }
                    1 => Err("fail".into()),
                    _ => {
                        (ctx.progress)(100, 100);
                        Ok(())
                    }
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let mut p1 = grouped_params("g1", "混合组", 100);
        p1.local_path = "/local/f1".into();
        let mut p2 = grouped_params("g1", "混合组", 200);
        p2.local_path = "/local/f2".into();
        let mut p3 = grouped_params("g1", "混合组", 300);
        p3.local_path = "/local/f3".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        let id3 = service.start_transfer(p3).unwrap();

        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Failed).await;
        wait_for_status(&service, &id3, TransferStatus::Completed).await;

        service.transfer_cancel(&id2).unwrap();

        let groups = service.transfer_groups();
        assert_eq!(groups.len(), 1);
        let g = &groups[0];
        assert_eq!(g.group_id, "g1");
        assert_eq!(g.group_name, "混合组");
        assert_eq!(g.total_count, 3);
        assert_eq!(g.completed_count, 3);
        assert_eq!(g.total_bytes, 600);
        assert_eq!(g.transferred_bytes, 400);
        assert_eq!(g.status, TransferStatus::Failed);
    }

    #[tokio::test]
    async fn group_status_reflects_priority_with_mixed_states() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(10000, 100, 50)));
        let mut p1 = grouped_params("g1", "优先级组", 100);
        p1.local_path = "/local/f1".into();
        p1.remote_path = "/remote/f1".into();
        let mut p2 = grouped_params("g1", "优先级组", 100);
        p2.local_path = "/local/f2".into();
        p2.remote_path = "/remote/f2".into();
        let mut p3 = grouped_params("g1", "优先级组", 100);
        p3.local_path = "/local/f3".into();
        p3.remote_path = "/remote/f3".into();

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        let id3 = service.start_transfer(p3).unwrap();

        wait_for_status(&service, &id1, TransferStatus::Running).await;

        service.transfer_pause(&id2).unwrap();
        wait_for_status(&service, &id2, TransferStatus::Paused).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.status, TransferStatus::Running);

        service.transfer_cancel(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Cancelled).await;

        // id1=Cancelled, id2=Paused, id3=Running → Running 优先
        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.status, TransferStatus::Running);

        service.transfer_cancel(&id3).unwrap();
        wait_for_status(&service, &id3, TransferStatus::Cancelled).await;

        // id1=Cancelled, id2=Paused, id3=Cancelled → Paused 优先
        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.status, TransferStatus::Paused);

        service.group_cancel("g1").unwrap();
        wait_for_status(&service, &id2, TransferStatus::Cancelled).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.status, TransferStatus::Cancelled);
    }

    #[tokio::test]
    async fn progress_updates_do_not_affect_group_status() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(1000, 100, 100)));
        let mut p1 = grouped_params("g1", "进度组", 1000);
        p1.local_path = "/local/f1".into();

        let id1 = service.start_transfer(p1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        let groups_before = service.transfer_groups();
        let g_before = groups_before.iter().find(|g| g.group_id == "g1").unwrap();
        let status_before = g_before.status;

        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;

        let groups_after = service.transfer_groups();
        let g_after = groups_after.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g_after.status, status_before);
        assert_eq!(g_after.status, TransferStatus::Running);

        wait_for_status(&service, &id1, TransferStatus::Completed).await;
    }

    #[tokio::test]
    async fn repeated_group_cancel_is_idempotent() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(10000, 100, 50)));
        let mut p1 = grouped_params("g1", "重复取消组", 100);
        p1.local_path = "/local/f1".into();

        let id1 = service.start_transfer(p1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;

        service.group_cancel("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Cancelled).await;

        service.group_cancel("g1").unwrap();
        let snap = service.transfer_status(&id1).unwrap();
        assert_eq!(snap.status, TransferStatus::Cancelled);

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.status, TransferStatus::Cancelled);
    }

    #[tokio::test]
    async fn group_operations_ignore_ungrouped_tasks() {
        let service = TransferService::new(Box::new(FakeExecutor::slow(10000, 100, 50)));
        let mut grouped = grouped_params("g1", "有组", 100);
        grouped.local_path = "/local/grouped".into();
        grouped.remote_path = "/remote/grouped".into();
        let ungrouped = TransferParams {
            direction: TransferDirection::Upload,
            host_id: "host-1".into(),
            local_path: "/local/ungrouped".into(),
            remote_path: "/remote/file".into(),
            size: 100,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        };

        let id_grouped = service.start_transfer(grouped).unwrap();
        let id_ungrouped = service.start_transfer(ungrouped).unwrap();
        wait_for_status(&service, &id_grouped, TransferStatus::Running).await;
        wait_for_status(&service, &id_ungrouped, TransferStatus::Running).await;

        service.group_cancel("g1").unwrap();
        wait_for_status(&service, &id_grouped, TransferStatus::Cancelled).await;

        let snap_ungrouped = service.transfer_status(&id_ungrouped).unwrap();
        assert_eq!(snap_ungrouped.status, TransferStatus::Running);

        let groups = service.transfer_groups();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].group_id, "g1");
    }

    // --- 5.1 组聚合状态、进度与清理 ---

    struct ConflictFakeExecutor {
        behavior: Arc<
            dyn Fn(TransferContext) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>>
                + Send
                + Sync,
        >,
    }

    impl ConflictFakeExecutor {
        fn conflict_then_success() -> Self {
            Self {
                behavior: Arc::new(|ctx| {
                    Box::pin(async move {
                        (ctx.progress)(100, 100);
                        Ok(())
                    })
                }),
            }
        }
    }

    impl TransferExecutor for ConflictFakeExecutor {
        fn execute(
            &self,
            ctx: TransferContext,
        ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
            (self.behavior)(ctx)
        }

        fn check_conflict(
            &self,
            _ctx: &TransferContext,
        ) -> Pin<Box<dyn Future<Output = Result<Option<ConflictInfo>, String>> + Send>> {
            Box::pin(async {
                Ok(Some(ConflictInfo {
                    source_size: 100,
                    source_mtime: Some(1000),
                    target_size: 50,
                    target_mtime: Some(900),
                }))
            })
        }
    }

    fn make_grouped_params(group_id: &str, group_name: &str, local: &str, remote: &str, size: u64) -> TransferParams {
        TransferParams {
            direction: TransferDirection::Upload,
            host_id: "host-1".into(),
            local_path: local.into(),
            remote_path: remote.into(),
            size,
            password: None,
            passphrase: None,
            group_id: Some(group_id.into()),
            group_name: Some(group_name.into()),
        }
    }

    #[tokio::test]
    async fn group_progress_aggregates_member_bytes() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 200);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            let groups = service.transfer_groups();
            groups.iter().any(|g| g.group_id == "g1" && g.completed_count == 2)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_count, 2);
        assert_eq!(g.completed_count, 2);
        assert_eq!(g.total_bytes, 300);
        assert_eq!(g.transferred_bytes, 300);
        assert_eq!(g.status, TransferStatus::Completed);
    }

    #[tokio::test]
    async fn group_completed_count_includes_skipped() {
        let executor = ConflictFakeExecutor::conflict_then_success();
        let service = TransferService::with_concurrency_and_conflict_timeout(
            Box::new(executor),
            3,
            None,
            1,
        );
        let mut p1 = make_grouped_params("g1", "跳过组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "跳过组", "/local/f2", "/remote/f2", 200);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            service.transfer_list().iter().all(|t| t.status == TransferStatus::Skipped)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_count, 2);
        assert_eq!(g.completed_count, 2);
    }

    #[tokio::test]
    async fn standalone_files_not_in_group_snapshot() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let p = TransferParams {
            direction: TransferDirection::Upload,
            host_id: "host-1".into(),
            local_path: "/local/standalone".into(),
            remote_path: "/remote/standalone".into(),
            size: 50,
            password: None,
            passphrase: None,
            group_id: None,
            group_name: None,
        };
        let _id = service.start_transfer(p).unwrap();

        until(|| {
            service.transfer_list().iter().all(|t| t.status.is_terminal())
        }).await;

        let groups = service.transfer_groups();
        assert!(groups.is_empty());
    }

    #[tokio::test]
    async fn group_single_file_failure_does_not_end_others() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();
        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            let is_first = n == 0;
            Box::pin(async move {
                if is_first {
                    Err("第一个文件失败".into())
                } else {
                    (ctx.progress)(100, 100);
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let mut p1 = make_grouped_params("g1", "混合组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "混合组", "/local/f2", "/remote/f2", 200);

        let id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            let snap = service.transfer_status(&id1).unwrap();
            snap.status == TransferStatus::Failed
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_count, 2);
        assert_eq!(g.status, TransferStatus::Failed);
    }

    #[tokio::test]
    async fn all_zero_byte_group_shows_zero_transferred() {
        let service = TransferService::new(Box::new(FakeExecutor::success()));
        let mut p1 = make_grouped_params("g1", "零字节组", "/local/f1", "/remote/f1", 0);
        let mut p2 = make_grouped_params("g1", "零字节组", "/local/f2", "/remote/f2", 0);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            let groups = service.transfer_groups();
            groups.iter().any(|g| g.group_id == "g1" && g.completed_count == 2)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_bytes, 0);
        assert_eq!(g.transferred_bytes, 0);
        assert_eq!(g.total_count, 2);
        assert_eq!(g.completed_count, 2);
    }

    #[tokio::test]
    async fn all_skipped_group_status_is_not_completed() {
        let executor = ConflictFakeExecutor::conflict_then_success();
        let service = TransferService::with_concurrency_and_conflict_timeout(
            Box::new(executor),
            3,
            None,
            1,
        );
        let mut p1 = make_grouped_params("g1", "全跳过组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "全跳过组", "/local/f2", "/remote/f2", 200);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            service.transfer_list().iter().all(|t| t.status == TransferStatus::Skipped)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_ne!(g.status, TransferStatus::Completed);
    }

    #[tokio::test]
    async fn mixed_group_partial_failure_aggregation() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();
        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            let should_fail = n == 0;
            Box::pin(async move {
                if should_fail {
                    Err("fail".into())
                } else {
                    (ctx.progress)(100, 100);
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let mut p1 = make_grouped_params("g1", "混合组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "混合组", "/local/f2", "/remote/f2", 200);
        let mut p3 = make_grouped_params("g1", "混合组", "/local/f3", "/remote/f3", 300);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();
        let _id3 = service.start_transfer(p3).unwrap();

        until(|| {
            let groups = service.transfer_groups();
            groups.iter().any(|g| g.group_id == "g1" && g.completed_count == 3)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_count, 3);
        assert_eq!(g.completed_count, 3);
        assert_eq!(g.total_bytes, 600);
        assert_eq!(g.status, TransferStatus::Failed);
    }

    #[tokio::test]
    async fn single_file_failure_preserves_group_total_count() {
        let executor = FakeExecutor::failure("always fail");
        let service = TransferService::new(Box::new(executor));
        let mut p1 = make_grouped_params("g1", "失败组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "失败组", "/local/f2", "/remote/f2", 200);

        let _id1 = service.start_transfer(p1).unwrap();
        let _id2 = service.start_transfer(p2).unwrap();

        until(|| {
            let groups = service.transfer_groups();
            groups.iter().any(|g| g.group_id == "g1" && g.completed_count == 2)
        }).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").unwrap();
        assert_eq!(g.total_count, 2);
        assert_eq!(g.completed_count, 2);
        assert_eq!(g.total_bytes, 300);
        assert_eq!(g.status, TransferStatus::Failed);
    }

    #[tokio::test]
    async fn group_status_priority_cascade_with_skipped() {
        let statuses = vec![TransferStatus::Skipped, TransferStatus::Completed];
        assert_ne!(group_status_priority(&statuses), TransferStatus::Completed);
    }

    #[tokio::test]
    async fn group_retry_retries_skipped_tasks() {
        let conflict_calls = Arc::new(AtomicUsize::new(0));
        let cc = conflict_calls.clone();
        let executor = FakeExecutor::custom(move |ctx| {
            Box::pin(async move {
                (ctx.progress)(100, 100);
                Ok(())
            })
        });

        struct CountingConflictExecutor {
            inner: FakeExecutor,
            calls: Arc<AtomicUsize>,
        }
        impl TransferExecutor for CountingConflictExecutor {
            fn execute(
                &self,
                ctx: TransferContext,
            ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
                self.inner.execute(ctx)
            }
            fn check_conflict(
                &self,
                _ctx: &TransferContext,
            ) -> Pin<Box<dyn Future<Output = Result<Option<ConflictInfo>, String>> + Send>> {
                let n = self.calls.fetch_add(1, Ordering::Relaxed);
                Box::pin(async move {
                    if n < 2 {
                        Ok(Some(ConflictInfo {
                            source_size: 100,
                            source_mtime: Some(1000),
                            target_size: 50,
                            target_mtime: Some(900),
                        }))
                    } else {
                        Ok(None)
                    }
                })
            }
        }

        let counting = CountingConflictExecutor {
            inner: executor,
            calls: cc,
        };

        let service = TransferService::with_concurrency_and_conflict_timeout(
            Box::new(counting),
            3,
            None,
            1,
        );
        let mut p1 = make_grouped_params("g1", "重试跳过组", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "重试跳过组", "/local/f2", "/remote/f2", 200);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();

        until(|| {
            let s1 = service.transfer_status(&id1).unwrap();
            let s2 = service.transfer_status(&id2).unwrap();
            s1.status == TransferStatus::Skipped && s2.status == TransferStatus::Skipped
        }).await;

        service.group_retry("g1").unwrap();

        until(|| {
            let s1 = service.transfer_status(&id1).unwrap();
            let s2 = service.transfer_status(&id2).unwrap();
            s1.status == TransferStatus::Completed && s2.status == TransferStatus::Completed
        }).await;
    }

    // --- 5.3 单成员操作隔离与终态一致性 ---

    #[tokio::test]
    async fn single_task_cancel_in_group_does_not_affect_others() {
        let service = TransferService::with_concurrency(Box::new(FakeExecutor::slow(100, 10, 20)), 4, None);
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 100);
        let mut p3 = make_grouped_params("g1", "组一", "/local/f3", "/remote/f3", 100);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        let id3 = service.start_transfer(p3).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;
        wait_for_status(&service, &id2, TransferStatus::Running).await;
        wait_for_status(&service, &id3, TransferStatus::Running).await;

        service.transfer_cancel(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Cancelled).await;

        let snap2 = service.transfer_status(&id2).unwrap();
        let snap3 = service.transfer_status(&id3).unwrap();
        assert_ne!(snap2.status, TransferStatus::Cancelled);
        assert_ne!(snap3.status, TransferStatus::Cancelled);
    }

    #[tokio::test]
    async fn single_task_pause_in_group_does_not_affect_others() {
        let service = TransferService::with_concurrency(Box::new(FakeExecutor::slow(100, 10, 20)), 4, None);
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 100);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;
        wait_for_status(&service, &id2, TransferStatus::Running).await;

        service.transfer_pause(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Paused).await;

        let snap2 = service.transfer_status(&id2).unwrap();
        assert_ne!(snap2.status, TransferStatus::Paused);
        assert_ne!(snap2.status, TransferStatus::Queued);
    }

    #[tokio::test]
    async fn single_task_cancel_does_not_affect_other_groups() {
        let service = TransferService::with_concurrency(Box::new(FakeExecutor::slow(100, 10, 20)), 4, None);
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g2", "组二", "/local/f2", "/remote/f2", 100);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Running).await;
        wait_for_status(&service, &id2, TransferStatus::Running).await;

        service.transfer_cancel(&id1).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Cancelled).await;

        let snap2 = service.transfer_status(&id2).unwrap();
        assert_ne!(snap2.status, TransferStatus::Cancelled);
    }

    #[tokio::test]
    async fn group_retry_preserves_paths() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |_ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                if n < 2 {
                    Err("fail".into())
                } else {
                    Ok(())
                }
            })
        });

        let service = TransferService::new(Box::new(executor));
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 200);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Failed).await;
        wait_for_status(&service, &id2, TransferStatus::Failed).await;

        service.group_retry("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;

        let snap1 = service.transfer_status(&id1).unwrap();
        assert_eq!(snap1.local_path, "/local/f1");
        assert_eq!(snap1.remote_path, "/remote/f1");
        let snap2 = service.transfer_status(&id2).unwrap();
        assert_eq!(snap2.local_path, "/local/f2");
        assert_eq!(snap2.remote_path, "/remote/f2");
    }

    #[tokio::test]
    async fn group_retry_does_not_reexecute_successful_members() {
        let exec_count = Arc::new(AtomicUsize::new(0));
        let exec_count_clone = exec_count.clone();

        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let my_attempt = attempt_clone.fetch_add(1, Ordering::Relaxed);
            exec_count_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                if my_attempt == 0 {
                    Err("fail".into())
                } else {
                    (ctx.progress)(100, 100);
                    Ok(())
                }
            })
        });

        let service = TransferService::with_concurrency(Box::new(executor), 1, None);
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 100);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Failed).await;
        wait_for_status(&service, &id2, TransferStatus::Completed).await;

        let count_before = exec_count.load(Ordering::Relaxed);
        assert_eq!(count_before, 2, "两个任务各执行一次");

        service.group_retry("g1").unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;

        let count_after = exec_count.load(Ordering::Relaxed);
        assert_eq!(count_after, 3, "只有失败的任务被重新执行");

        let snap2 = service.transfer_status(&id2).unwrap();
        assert_eq!(snap2.status, TransferStatus::Completed);
    }

    #[tokio::test]
    async fn all_terminal_group_snapshot_consistent() {
        let attempt = Arc::new(AtomicUsize::new(0));
        let attempt_clone = attempt.clone();

        let executor = FakeExecutor::custom(move |ctx| {
            let n = attempt_clone.fetch_add(1, Ordering::Relaxed);
            Box::pin(async move {
                match n {
                    0 => {
                        (ctx.progress)(100, 100);
                        Ok(())
                    }
                    1 => Err("fail".into()),
                    _ => {
                        (ctx.progress)(100, 100);
                        Ok(())
                    }
                }
            })
        });

        let service = TransferService::with_concurrency(Box::new(executor), 1, None);
        let mut p1 = make_grouped_params("g1", "组一", "/local/f1", "/remote/f1", 100);
        let mut p2 = make_grouped_params("g1", "组一", "/local/f2", "/remote/f2", 100);
        let mut p3 = make_grouped_params("g1", "组一", "/local/f3", "/remote/f3", 100);

        let id1 = service.start_transfer(p1).unwrap();
        let id2 = service.start_transfer(p2).unwrap();
        let id3 = service.start_transfer(p3).unwrap();
        wait_for_status(&service, &id1, TransferStatus::Completed).await;
        wait_for_status(&service, &id2, TransferStatus::Failed).await;
        wait_for_status(&service, &id3, TransferStatus::Completed).await;

        service.transfer_cancel(&id2).unwrap();
        wait_for_status(&service, &id2, TransferStatus::Failed).await;

        let groups = service.transfer_groups();
        let g = groups.iter().find(|g| g.group_id == "g1").expect("g1 应存在");
        assert_eq!(g.total_count, 3);
        assert_eq!(g.completed_count, 3, "所有成员均为终态");

        let statuses: Vec<_> = [id1.as_str(), id2.as_str(), id3.as_str()]
            .iter()
            .map(|id| service.transfer_status(id).unwrap().status)
            .collect();
        assert!(statuses.iter().all(|s| s.is_terminal()));
    }
}
