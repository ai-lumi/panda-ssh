use super::*;

pub struct DirectoryContext {
    pub direction: TransferDirection,
    pub host_id: String,
    pub password: Option<String>,
    pub passphrase: Option<String>,
}

pub trait DirectoryWriter: Send + Sync {
    fn create_dir_all<'a>(
        &'a self,
        path: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send + 'a>>;
}

#[derive(Debug, Clone)]
pub struct DirectoryPreparationSnapshot {
    pub source: String,
    pub destination: String,
    pub status: TransferStatus,
    pub error: Option<String>,
}

#[derive(Default)]
pub(super) struct DirectoryRun {
    cancelled: AtomicBool,
    notify: Notify,
}

impl DirectoryRun {
    async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.cancelled.load(Ordering::Acquire) {
                return;
            }
            notified.await;
        }
    }
}

pub(super) struct DirectoryGroup {
    pub snapshot: DirectoryGroupSnapshot,
    pub run: Arc<DirectoryRun>,
}

impl DirectoryGroup {
    pub fn new(snapshot: DirectoryGroupSnapshot) -> Self {
        Self { snapshot, run: Arc::new(DirectoryRun::default()) }
    }

    pub fn cancel(&mut self) {
        if !self.snapshot.status.is_terminal() {
            self.snapshot.status = TransferStatus::Cancelled;
            for directory in &mut self.snapshot.directories {
                if !directory.status.is_terminal() {
                    directory.status = TransferStatus::Cancelled;
                }
            }
            self.run.cancelled.store(true, Ordering::Release);
            self.run.notify.notify_waiters();
        }
    }

    pub fn files_ready(&self) -> bool {
        matches!(self.snapshot.status, TransferStatus::Completed | TransferStatus::Failed)
    }

    pub fn dependency_error(&self, task: &TransferTask) -> Option<String> {
        let destination = match task.direction {
            TransferDirection::Upload => &task.remote_path,
            TransferDirection::Download => &task.local_path,
        };
        self.snapshot.directories.iter().find(|directory| {
            directory.status != TransferStatus::Completed
                && within(destination, &directory.destination)
        }).and_then(|directory| directory.error.clone())
    }
}

fn within(path: &str, directory: &str) -> bool {
    path == directory || path.starts_with(&format!("{}/", directory.trim_end_matches('/')))
}

pub(super) async fn run_preparation(
    inner: Arc<ServiceInner>,
    group_id: String,
    run: Arc<DirectoryRun>,
) {
    let permit = tokio::select! {
        biased;
        _ = run.cancelled() => return,
        permit = inner.semaphore.acquire() => match permit {
            Ok(permit) => permit,
            Err(_) => return,
        },
    };
    let snapshot = {
        let mut registry = inner.registry.lock().unwrap();
        if !registry.accepting || run.cancelled.load(Ordering::Acquire) {
            return;
        }
        let group = registry.groups.get_mut(&group_id).unwrap();
        group.snapshot.status = TransferStatus::Running;
        inner.bump_revision();
        group.snapshot.clone()
    };
    inner.emit_changed();
    let service = TransferService { inner: inner.clone() };
    let params = service.operation_params(&snapshot.operation_id).unwrap();
    let result = tokio::select! {
        biased;
        _ = run.cancelled() => return,
        result = async {
            let writer = inner.executor.open_directory(DirectoryContext {
                direction: params.direction,
                host_id: params.host_id,
                password: params.password,
                passphrase: params.passphrase,
            }).await.map_err(|error| format!("{} → {}: {error}", snapshot.plan.source_root, snapshot.plan.destination_root))?;
            let mut directories = snapshot.directories;
            directories.sort_by(|a, b| a.destination.cmp(&b.destination));
            let mut failures: Vec<(String, String)> = Vec::new();
            for directory in directories {
                let result = match failures.iter().find(|(path, _)| within(&directory.destination, path)) {
                    Some((_, error)) => Err(error.clone()),
                    None => writer.create_dir_all(&directory.destination).await.map_err(|error| {
                        format!("{} → {}: {error}", directory.source, directory.destination)
                    }),
                };
                if let Err(error) = &result {
                    failures.push((directory.destination.clone(), error.clone()));
                }
                let mut registry = inner.registry.lock().unwrap();
                if run.cancelled.load(Ordering::Acquire) { return Ok(()); }
                let group = registry.groups.get_mut(&group_id).unwrap();
                let entry = group.snapshot.directories.iter_mut().find(|d| d.destination == directory.destination).unwrap();
                entry.status = if result.is_ok() { TransferStatus::Completed } else { TransferStatus::Failed };
                entry.error = result.err();
                inner.bump_revision();
                drop(registry);
                inner.emit_changed();
            }
            Ok::<(), String>(())
        } => result,
    };
    drop(permit);
    let mut registry = inner.registry.lock().unwrap();
    if !registry.accepting || run.cancelled.load(Ordering::Acquire) {
        return;
    }
    let group = registry.groups.get_mut(&group_id).unwrap();
    if let Err(error) = result {
        for directory in &mut group.snapshot.directories {
            if directory.status != TransferStatus::Completed {
                directory.status = TransferStatus::Failed;
                directory.error = Some(error.clone());
            }
        }
    }
    let errors: Vec<_> = group.snapshot.directories.iter().filter_map(|d| d.error.as_deref()).collect();
    group.snapshot.error = (!errors.is_empty()).then(|| errors.join("\n"));
    group.snapshot.status = if errors.is_empty() { TransferStatus::Completed } else { TransferStatus::Failed };
    let mut ready = Vec::new();
    let group = &registry.groups[&group_id];
    for task in registry.tasks.values().filter(|task| task.group_id.as_deref() == Some(&group_id)) {
        if task.status.lock().unwrap().is_terminal() {
            continue;
        }
        if let Some(error) = group.dependency_error(task) {
            *task.status.lock().unwrap() = TransferStatus::Failed;
            *task.error.lock().unwrap() = Some(error);
            task.bump_version();
        } else {
            ready.push(task.clone());
        }
    }
    inner.bump_revision();
    drop(registry);
    inner.emit_changed();
    for task in ready {
        tokio::spawn(run_transfer_task(inner.clone(), task));
    }
}
