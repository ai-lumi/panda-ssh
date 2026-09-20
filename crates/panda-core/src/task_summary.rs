//! 类型化工作摘要与准备登记；执行器负责提供事实，UI 不判断业务终态。

use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum WorkKind {
    Upload,
    Download,
    LocalDelete,
    RemoteDelete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkStatus {
    Preparing,
    Scanning,
    Queued,
    Running,
    Paused,
    WaitingForDecision,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
}

impl WorkStatus {
    pub fn is_unfinished(self) -> bool {
        !matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressUnit {
    Bytes,
    Items,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkFailure {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkSnapshot {
    pub id: String,
    pub operation_id: Option<String>,
    pub group_id: Option<String>,
    pub kind: WorkKind,
    pub status: WorkStatus,
    pub host_id: Option<String>,
    pub source: String,
    pub destination: Option<String>,
    pub unit: ProgressUnit,
    pub processed: u64,
    pub total: Option<u64>,
    pub discovered: u64,
    pub succeeded: u64,
    pub current_path: Option<String>,
    pub errors: Vec<WorkFailure>,
}

impl WorkSnapshot {
    pub fn new(id: String, kind: WorkKind, status: WorkStatus, source: String) -> Self {
        Self {
            id,
            kind,
            status,
            source,
            operation_id: None,
            group_id: None,
            host_id: None,
            destination: None,
            unit: match kind {
                WorkKind::Upload | WorkKind::Download => ProgressUnit::Bytes,
                WorkKind::LocalDelete | WorkKind::RemoteDelete => ProgressUnit::Items,
            },
            processed: 0,
            total: None,
            discovered: 0,
            succeeded: 0,
            current_path: None,
            errors: Vec::new(),
        }
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct UnfinishedSummary {
    pub total: u64,
    pub by_kind: BTreeMap<WorkKind, u64>,
}

/// 操作、展示组、独立任务分别使用不同的标识域，防止字符串碰撞。
pub fn summarize_unfinished(tasks: &[WorkSnapshot]) -> UnfinishedSummary {
    let mut seen = HashSet::new();
    let mut result = UnfinishedSummary::default();
    for task in tasks.iter().filter(|task| task.status.is_unfinished()) {
        let key = if let Some(id) = &task.operation_id {
            (0, id)
        } else if let Some(id) = &task.group_id {
            (1, id)
        } else {
            (2, &task.id)
        };
        if seen.insert(key) {
            result.total += 1;
            *result.by_kind.entry(task.kind).or_default() += 1;
        }
    }
    result
}

/// 外层适配器须在同一互斥锁内执行登记、执行器插入与最终退出核验。
pub struct WorkRegistry {
    accepting: bool,
    preparations: BTreeMap<String, WorkSnapshot>,
    owners: HashMap<String, String>,
    handed_off: HashSet<String>,
}

impl Default for WorkRegistry {
    fn default() -> Self {
        Self {
            accepting: true,
            preparations: BTreeMap::new(),
            owners: HashMap::new(),
            handed_off: HashSet::new(),
        }
    }
}

impl WorkRegistry {
    pub fn ensure_accepting(&self) -> Result<(), String> {
        if self.accepting {
            Ok(())
        } else {
            Err("应用正在退出，不能启动新任务".into())
        }
    }

    pub fn begin(&mut self, mut task: WorkSnapshot) -> Result<(), String> {
        self.ensure_accepting()?;
        if self.preparations.contains_key(&task.id) {
            return Err("准备操作已登记".into());
        }
        task.operation_id = Some(task.id.clone());
        self.preparations.insert(task.id.clone(), task);
        Ok(())
    }

    pub fn attach(&mut self, operation: &str, task: &str) -> Result<(), String> {
        self.ensure_accepting()?;
        let preparation = self.preparations.get(operation).ok_or("准备操作不存在")?;
        if !preparation.status.is_unfinished() || self.handed_off.contains(operation) {
            return Err("准备操作已经结束".into());
        }
        if let Some(owner) = self.owners.get(task) {
            if owner != operation {
                return Err("任务已属于其他操作".into());
            }
        }
        self.owners.insert(task.into(), operation.into());
        Ok(())
    }

    pub fn finish_preparation(
        &mut self,
        operation: &str,
        error: Option<String>,
    ) -> Result<(), String> {
        let task = self
            .preparations
            .get_mut(operation)
            .ok_or("准备操作不存在")?;
        if !task.status.is_unfinished() {
            return Ok(());
        }
        task.status = if let Some(message) = error {
            task.errors.push(WorkFailure {
                path: task.source.clone(),
                message,
            });
            WorkStatus::Failed
        } else {
            WorkStatus::Completed
        };
        self.handed_off.insert(operation.into());
        Ok(())
    }

    pub fn snapshots(&self, running: &[WorkSnapshot]) -> Vec<WorkSnapshot> {
        let mut result = running.to_vec();
        let mut represented = HashSet::new();
        for task in &mut result {
            if let Some(owner) = self.owners.get(&task.id) {
                task.operation_id = Some(owner.clone());
                represented.insert(owner.as_str());
            }
        }
        for (id, task) in &self.preparations {
            // 未完成准备始终保留；交接后有子任务时只保留子任务。
            if !self.handed_off.contains(id)
                || !represented.contains(id.as_str())
                || task.status == WorkStatus::Failed
            {
                result.push(task.clone());
            }
        }
        result
    }

    pub fn confirm_quit(&mut self, running: &[WorkSnapshot], force: bool) -> bool {
        if force || summarize_unfinished(&self.snapshots(running)).total == 0 {
            self.accepting = false;
            true
        } else {
            false
        }
    }

    pub fn cancel_quit(&mut self) {
        self.accepting = true;
    }

    pub fn clear_finished(&mut self) {
        self.preparations
            .retain(|_, task| task.status.is_unfinished());
        self.handed_off
            .retain(|id| self.preparations.contains_key(id));
        // 运行中的执行器仍需要操作关联，不能在清除历史展示时移除 owners。
    }
}
