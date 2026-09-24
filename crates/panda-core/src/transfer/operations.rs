//! 准备操作与文件、目录组的原子交接。
use super::*;
use crate::sftp_orchestration::{PlannedGroup, SftpOrchestrationPlan};
use crate::task_summary::{UnfinishedSummary, WorkFailure, WorkKind, WorkSnapshot, WorkStatus};
use tokio::sync::watch;

/// 操作拥有输入与凭据；该类型不用于快照，也不实现 Debug。
#[derive(Clone)]
pub struct TransferOperationParams {
    pub direction: TransferDirection,
    pub host_id: String,
    pub sources: Vec<String>,
    pub destination_dir: String,
    pub password: Option<String>,
    pub passphrase: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferOperationStatus {
    Scanning,
    HandedOff,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone)]
pub struct TransferOperationSnapshot {
    pub id: String,
    pub direction: TransferDirection,
    pub host_id: String,
    pub sources: Vec<String>,
    pub destination_dir: String,
    pub status: TransferOperationStatus,
    pub error: Option<String>,
    pub task_ids: Vec<String>,
    pub group_ids: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct DirectoryGroupSnapshot {
    pub operation_id: String,
    pub direction: TransferDirection,
    pub host_id: String,
    pub plan: PlannedGroup,
    pub status: TransferStatus,
    pub error: Option<String>,
    pub directories: Vec<DirectoryPreparationSnapshot>,
}

#[derive(Debug)]
pub struct TransferRegistrySnapshot {
    pub revision: u64,
    pub accepting: bool,
    pub operations: Vec<TransferOperationSnapshot>,
    pub transfers: Vec<TransferSnapshot>,
    pub groups: Vec<DirectoryGroupSnapshot>,
    /// 已按操作关联的事实，交给共享摘要函数去重，不把组冒充文件。
    pub work: Vec<WorkSnapshot>,
}

impl TransferRegistrySnapshot {
    pub fn unfinished_summary(&self) -> UnfinishedSummary {
        crate::task_summary::summarize_unfinished(&self.work)
    }
}

pub(super) struct OperationRecord {
    snapshot: TransferOperationSnapshot,
    params: TransferOperationParams,
    cancel: watch::Sender<bool>,
}

pub(super) struct TransferRegistry {
    pub tasks: HashMap<Uuid, Arc<TransferTask>>,
    pub groups: HashMap<String, directories::DirectoryGroup>,
    operations: HashMap<Uuid, OperationRecord>,
    pub accepting: bool,
    pub pending_conflicts: HashMap<Uuid, Arc<super::ConflictResolver>>,
}

impl Default for TransferRegistry {
    fn default() -> Self {
        Self {
            tasks: HashMap::new(),
            groups: HashMap::new(),
            operations: HashMap::new(),
            accepting: true,
            pending_conflicts: HashMap::new(),
        }
    }
}

impl TransferRegistry {
    pub fn ensure_accepting(&self) -> Result<(), Error> {
        if self.accepting {
            Ok(())
        } else {
            Err(Error::Other("应用正在退出，不能启动新任务".into()))
        }
    }

    fn cancel_operation(&mut self, id: Uuid) -> Result<(), Error> {
        let op = self
            .operations
            .get_mut(&id)
            .ok_or_else(|| Error::Other(format!("未知操作: {id}")))?;
        if op.snapshot.status == TransferOperationStatus::Scanning {
            op.snapshot.status = TransferOperationStatus::Cancelled;
            op.snapshot.error = Some("扫描已取消".into());
            let _ = op.cancel.send(true);
        }
        for task in self
            .tasks
            .values()
            .filter(|t| t.operation_id.as_deref() == Some(&op.snapshot.id))
        {
            cancel_task(task);
        }
        for group in self
            .groups
            .values_mut()
            .filter(|g| g.snapshot.operation_id == op.snapshot.id)
        {
            group.cancel();
        }
        Ok(())
    }
}

pub(super) fn cancel_task(task: &TransferTask) {
    let mut status = task.status.lock().unwrap();
    if !status.is_terminal() {
        task.cancel.store(true, Ordering::Release);
        *status = TransferStatus::Cancelled;
        task.bump_version();
        task.resume_notify.notify_waiters();
    }
}

impl TransferService {
    /// 同步登记并返回稳定标识；扫描适配器只产出数据，不得入队或写入目标。
    /// 适配器在后台任务内调用，收到本次操作固定的路径和凭据副本。
    pub fn start_operation<F, Fut>(
        &self,
        params: TransferOperationParams,
        scan: F,
    ) -> Result<Option<String>, Error>
    where
        F: FnOnce(TransferOperationParams) -> Fut + Send + 'static,
        Fut: Future<Output = Result<SftpOrchestrationPlan, Error>> + Send + 'static,
    {
        let mut registry = self.inner.registry.lock().unwrap();
        registry.ensure_accepting()?;
        if params.sources.is_empty() {
            return Ok(None);
        }
        let id = Uuid::new_v4();
        let (cancel, mut cancelled) = watch::channel(false);
        registry.operations.insert(
            id,
            OperationRecord {
                snapshot: TransferOperationSnapshot {
                    id: id.to_string(),
                    direction: params.direction,
                    host_id: params.host_id.clone(),
                    sources: params.sources.clone(),
                    destination_dir: params.destination_dir.clone(),
                    status: TransferOperationStatus::Scanning,
                    error: None,
                    task_ids: vec![],
                    group_ids: vec![],
                },
                params: params.clone(),
                cancel,
            },
        );
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();
        let service = self.clone();
        tokio::spawn(async move {
            let Ok(params) = service.operation_params(&id.to_string()) else {
                return;
            };
            // 取消优先，丢弃扫描 future；即便完成与取消竞争，交接还会在锁内再次核验。
            let result = tokio::select! {
                biased;
                _ = cancelled.changed() => return,
                result = async { scan(params.clone()).await } => result,
            };
            service.finish_operation(id, params, result);
        });
        Ok(Some(id.to_string()))
    }

    fn finish_operation(
        &self,
        id: Uuid,
        params: TransferOperationParams,
        result: Result<SftpOrchestrationPlan, Error>,
    ) {
        let mut registry = self.inner.registry.lock().unwrap();
        if !registry.accepting
            || registry.operations[&id].snapshot.status != TransferOperationStatus::Scanning
        {
            return;
        }
        let mut ready = Vec::new();
        let mut preparations = Vec::new();
        match result {
            Err(error) => {
                let op = &mut registry.operations.get_mut(&id).unwrap().snapshot;
                op.status = TransferOperationStatus::Failed;
                op.error = Some(error.to_string());
            }
            Ok(plan) => {
                let operation_id = id.to_string();
                let mut group_ids = Vec::new();
                for group in plan.groups {
                    group_ids.push(group.group_id.clone());
                    let record = directories::DirectoryGroup::new(DirectoryGroupSnapshot {
                        operation_id: operation_id.clone(),
                        direction: params.direction,
                        host_id: params.host_id.clone(),
                        directories: group.directories.iter().map(|d| DirectoryPreparationSnapshot {
                            source: d.source.clone(), destination: d.destination.clone(),
                            status: TransferStatus::Queued, error: None,
                        }).collect(),
                        plan: group,
                        status: TransferStatus::Queued,
                        error: None,
                    });
                    preparations.push((record.snapshot.plan.group_id.clone(), record.run.clone()));
                    registry.groups.insert(record.snapshot.plan.group_id.clone(), record);
                }
                let mut task_ids = Vec::new();
                for file in plan.transfers {
                    let (local_path, remote_path) = match params.direction {
                        TransferDirection::Upload => (file.source, file.destination),
                        TransferDirection::Download => (file.destination, file.source),
                    };
                    let task = Arc::new(TransferTask::new(
                        TransferParams {
                            direction: params.direction,
                            host_id: params.host_id.clone(),
                            local_path,
                            remote_path,
                            size: file.size,
                            password: params.password.clone(),
                            passphrase: params.passphrase.clone(),
                            group_id: file.group_id,
                            group_name: file.group_name,
                        },
                        Some(operation_id.clone()),
                    ));
                    task_ids.push(task.id.to_string());
                    // 目录执行器接入后负责放行成员；此处不能越过准备阶段。
                    if task.group_id.is_none() {
                        ready.push(task.clone());
                    }
                    registry.tasks.insert(task.id, task);
                }
                let op = &mut registry.operations.get_mut(&id).unwrap().snapshot;
                op.status = TransferOperationStatus::HandedOff;
                op.task_ids = task_ids;
                op.group_ids = group_ids;
            }
        }
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();
        for (group_id, run) in preparations {
            tokio::spawn(directories::run_preparation(self.inner.clone(), group_id, run));
        }
        for task in ready {
            let inner = self.inner.clone();
            tokio::spawn(run_transfer_task(inner, task));
        }
    }

    /// 仅供核心执行器取执行资源，不经过任何公开快照。
    pub(super) fn operation_params(&self, id: &str) -> Result<TransferOperationParams, Error> {
        let id = Uuid::parse_str(id).map_err(|e| Error::Other(format!("无效操作 id: {e}")))?;
        self.inner
            .registry
            .lock()
            .unwrap()
            .operations
            .get(&id)
            .map(|op| op.params.clone())
            .ok_or_else(|| Error::Other(format!("未知操作: {id}")))
    }

    pub fn operation_status(&self, id: &str) -> Result<TransferOperationSnapshot, Error> {
        let id = Uuid::parse_str(id).map_err(|e| Error::Other(format!("无效操作 id: {e}")))?;
        self.inner
            .registry
            .lock()
            .unwrap()
            .operations
            .get(&id)
            .map(|op| op.snapshot.clone())
            .ok_or_else(|| Error::Other(format!("未知操作: {id}")))
    }

    /// 扫描中中断扫描，交接后只取消此操作仍未结束的成员。
    pub fn cancel_operation(&self, id: &str) -> Result<(), Error> {
        let id = Uuid::parse_str(id).map_err(|e| Error::Other(format!("无效操作 id: {e}")))?;
        let mut registry = self.inner.registry.lock().unwrap();
        registry.cancel_operation(id)?;
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();
        Ok(())
    }

    pub fn registry_snapshot(&self) -> TransferRegistrySnapshot {
        let registry = self.inner.registry.lock().unwrap();
        let mut operations: Vec<_> = registry
            .operations
            .values()
            .map(|op| op.snapshot.clone())
            .collect();
        operations.sort_by(|a, b| a.id.cmp(&b.id));
        let mut transfers: Vec<_> = registry
            .tasks
            .values()
            .map(|task| task.snapshot())
            .collect();
        transfers.sort_by(|a, b| a.id.cmp(&b.id));
        let mut groups: Vec<_> = registry.groups.values().map(|g| g.snapshot.clone()).collect();
        groups.sort_by(|a, b| a.plan.group_id.cmp(&b.plan.group_id));
        let mut work = Vec::new();
        for op in &operations {
            if op.status == TransferOperationStatus::HandedOff
                && (!op.task_ids.is_empty() || !op.group_ids.is_empty())
            {
                continue;
            }
            let status = match op.status {
                TransferOperationStatus::Scanning => WorkStatus::Scanning,
                TransferOperationStatus::HandedOff => WorkStatus::Completed,
                TransferOperationStatus::Failed => WorkStatus::Failed,
                TransferOperationStatus::Cancelled => WorkStatus::Cancelled,
            };
            let mut item = work_snapshot(
                op.id.clone(),
                Some(op.id.clone()),
                op.direction,
                status,
                &op.host_id,
                op.sources.first().cloned().unwrap_or_default(),
                op.destination_dir.clone(),
            );
            if let Some(error) = &op.error {
                item.errors.push(WorkFailure {
                    path: item.source.clone(),
                    message: error.clone(),
                });
            }
            work.push(item);
        }
        for task in &transfers {
            let (source, destination) = match task.direction {
                TransferDirection::Upload => (&task.local_path, &task.remote_path),
                TransferDirection::Download => (&task.remote_path, &task.local_path),
            };
            let owner = registry.tasks[&Uuid::parse_str(&task.id).unwrap()]
                .operation_id
                .clone();
            let mut item = work_snapshot(
                task.id.clone(),
                owner,
                task.direction,
                work_status(task.status),
                &task.host_id,
                source.clone(),
                destination.clone(),
            );
            item.group_id = task.group_id.clone();
            item.processed = task.transferred;
            item.total = Some(task.size);
            work.push(item);
        }
        for group in &groups {
            let mut item = work_snapshot(
                group.plan.group_id.clone(),
                Some(group.operation_id.clone()),
                group.direction,
                work_status(group.status),
                &group.host_id,
                group.plan.source_root.clone(),
                group.plan.destination_root.clone(),
            );
            item.group_id = Some(group.plan.group_id.clone());
            work.push(item);
        }
        TransferRegistrySnapshot {
            revision: self.change_counter(),
            accepting: registry.accepting,
            operations,
            transfers,
            groups,
            work,
        }
    }

    /// 在登记临界区关闭入口并取消全部在途工作；迟到扫描不能再次入队。
    pub fn shutdown(&self) {
        let mut registry = self.inner.registry.lock().unwrap();
        registry.accepting = false;
        let ids: Vec<_> = registry.operations.keys().copied().collect();
        for id in ids {
            let _ = registry.cancel_operation(id);
        }
        for task in registry.tasks.values() {
            cancel_task(task);
        }
        self.inner.bump_revision();
        drop(registry);
        self.inner.emit_changed();
    }
}

fn work_status(status: TransferStatus) -> WorkStatus {
    match status {
        TransferStatus::Queued => WorkStatus::Queued,
        TransferStatus::Running => WorkStatus::Running,
        TransferStatus::Paused => WorkStatus::Paused,
        TransferStatus::Completed => WorkStatus::Completed,
        TransferStatus::Failed => WorkStatus::Failed,
        TransferStatus::Cancelled => WorkStatus::Cancelled,
        TransferStatus::Skipped => WorkStatus::Skipped,
    }
}

fn work_snapshot(
    id: String,
    operation_id: Option<String>,
    direction: TransferDirection,
    status: WorkStatus,
    host: &str,
    source: String,
    destination: String,
) -> WorkSnapshot {
    let kind = match direction {
        TransferDirection::Upload => WorkKind::Upload,
        TransferDirection::Download => WorkKind::Download,
    };
    let mut work = WorkSnapshot::new(id, kind, status, source);
    work.operation_id = operation_id;
    work.host_id = Some(host.into());
    work.destination = Some(destination);
    work
}
