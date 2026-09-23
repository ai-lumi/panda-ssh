//! 批量 SFTP 传输：递归扫描本地/远程目录，生成批量传输计划。

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use uuid::Uuid;

use crate::sftp::SftpClient;
use crate::{Error, Result};

/// 批量传输中的单个项目。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchItem {
    /// 源路径（本地或远程绝对路径）。
    pub source: String,
    /// 目标路径（本地或远程绝对路径）。
    pub destination: String,
    /// 文件大小（字节）；目录本身为 0。
    pub size: u64,
    /// 是否为目录项（用于创建空目录）。
    pub is_dir: bool,
}

/// 批量传输计划：扫描结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchPlan {
    /// 所有待传输项目（文件与空目录）。
    pub items: Vec<BatchItem>,
    /// 总字节数（仅文件）。
    pub total_size: u64,
}

/// 扫描选项。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScanOptions {
    /// 是否跟随符号链接。默认 false（按链接本身处理，不进入指向内容）。
    pub follow_symlinks: bool,
    /// 最大递归深度，用于防止异常深目录。默认 100。
    pub max_depth: usize,
}

impl Default for ScanOptions {
    fn default() -> Self {
        Self {
            follow_symlinks: false,
            max_depth: 100,
        }
    }
}

/// 批量传输执行选项。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatchTransferOptions {
    /// 遇到错误时是否立即停止。默认 false（记录错误并继续）。
    pub stop_on_error: bool,
}

impl Default for BatchTransferOptions {
    fn default() -> Self {
        Self {
            stop_on_error: false,
        }
    }
}

/// 单个文件冲突的决策。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictResolution {
    /// 覆盖目标文件。
    Overwrite,
    /// 跳过该文件。
    Skip,
}

/// 批量传输执行结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchOutcome {
    /// 成功传输的源路径列表。
    pub completed: Vec<String>,
    /// 因冲突被跳过的源路径列表。
    pub skipped: Vec<String>,
    /// 失败的源路径及错误信息列表。
    pub errors: Vec<String>,
    /// 是否因用户取消而提前结束。
    pub cancelled: bool,
}

/// 批量传输进度回调类型。
pub type BatchProgressCallback = Arc<dyn Fn(u64, u64) + Send + Sync>;

/// 批量传输冲突回调类型：返回对当前冲突的决策。
pub type BatchConflictCallback =
    Arc<dyn Fn(&BatchItem, &crate::sftp::FileConflictInfo) -> ConflictResolution + Send + Sync>;

/// 本地已访问目录的 inode 标识，用于循环检测。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct LocalInode {
    dev: u64,
    ino: u64,
}

#[cfg(unix)]
fn local_inode(meta: &std::fs::Metadata) -> LocalInode {
    use std::os::unix::fs::MetadataExt;
    LocalInode {
        dev: meta.dev(),
        ino: meta.ino(),
    }
}

#[cfg(not(unix))]
fn local_inode(_meta: &std::fs::Metadata) -> LocalInode {
    LocalInode { dev: 0, ino: 0 }
}

/// 扫描多个本地源路径，生成批量上传计划。
///
/// 每个 source 的 basename 被放置到 `dest_dir` 下；目录会被递归展开。
/// 例如：source `/home/user/README.md` + dest_dir `/remote/project` →
/// destination `/remote/project/README.md`。
pub async fn scan_local_sources(
    sources: &[PathBuf],
    dest_dir: &str,
    options: &ScanOptions,
) -> Result<BatchPlan> {
    let mut items = Vec::new();
    let mut total_size = 0u64;
    let mut visited: HashSet<LocalInode> = HashSet::new();

    #[derive(Debug)]
    struct Frame {
        source: PathBuf,
        dest: String,
        depth: usize,
    }

    let mut stack: Vec<Frame> = sources
        .iter()
        .map(|source| Frame {
            dest: join_path(
                dest_dir,
                source.file_name().and_then(|n| n.to_str()).unwrap_or(""),
            ),
            source: source.clone(),
            depth: 0,
        })
        .collect();

    while let Some(frame) = stack.pop() {
        if frame.depth > options.max_depth {
            return Err(Error::Other(format!(
                "max scan depth exceeded at {}",
                frame.source.display()
            )));
        }

        let link_meta = tokio::fs::symlink_metadata(&frame.source).await?;
        let is_symlink = link_meta.is_symlink();

        // 决定实际类型与大小。若跟随符号链接，使用目标元数据并做循环检测。
        // 普通目录同样记录 inode，防止通过硬链接或符号链接再次进入同一目录。
        let (is_dir, size, is_loop) = if is_symlink && options.follow_symlinks {
            match tokio::fs::metadata(&frame.source).await {
                Ok(target_meta) => {
                    if target_meta.is_dir() {
                        let inode = local_inode(&target_meta);
                        let is_loop = inode.ino != 0 && !visited.insert(inode);
                        (true, 0, is_loop)
                    } else {
                        (false, target_meta.len(), false)
                    }
                }
                Err(_) => (false, link_meta.len(), false),
            }
        } else if link_meta.is_dir() {
            let inode = local_inode(&link_meta);
            let is_loop = inode.ino != 0 && !visited.insert(inode);
            (true, 0, is_loop)
        } else {
            (false, link_meta.len(), false)
        };

        if is_dir {
            // 记录目录项，即使为空也会创建；循环目录同样记录自身但不递归子项。
            items.push(BatchItem {
                source: frame.source.to_string_lossy().to_string(),
                destination: frame.dest.clone(),
                size: 0,
                is_dir: true,
            });

            if is_loop {
                continue;
            }

            let mut entries = tokio::fs::read_dir(&frame.source).await?;
            while let Some(entry) = entries.next_entry().await? {
                let child = entry.path();
                let child_dest =
                    join_path(&frame.dest, entry.file_name().to_string_lossy().as_ref());
                stack.push(Frame {
                    source: child,
                    dest: child_dest,
                    depth: frame.depth + 1,
                });
            }
        } else {
            total_size += size;
            items.push(BatchItem {
                source: frame.source.to_string_lossy().to_string(),
                destination: frame.dest,
                size,
                is_dir: false,
            });
        }
    }

    Ok(BatchPlan { items, total_size })
}

fn join_path(dir: &str, name: &str) -> String {
    crate::sftp_path::join_path(dir, name)
}

/// 扫描多个远程源路径，生成本地下载计划。
///
/// 每个 source 的 basename 被放置到 `dest_dir` 下；远程目录会被递归展开。
pub async fn scan_remote_sources(
    client: &SftpClient,
    sources: &[String],
    dest_dir: &str,
    options: &ScanOptions,
) -> Result<BatchPlan> {
    let mut items = Vec::new();
    let mut total_size = 0u64;
    let mut visited: HashSet<String> = HashSet::new();

    #[derive(Debug)]
    struct Frame {
        source: String,
        dest: String,
        depth: usize,
    }

    let mut stack: Vec<Frame> = sources
        .iter()
        .map(|source| Frame {
            dest: join_path(
                dest_dir,
                source.rsplit('/').next().unwrap_or(source.as_str()),
            ),
            source: source.clone(),
            depth: 0,
        })
        .collect();

    while let Some(frame) = stack.pop() {
        if frame.depth > options.max_depth {
            return Err(Error::Other(format!(
                "max scan depth exceeded at {}",
                frame.source
            )));
        }

        // 远程路径循环检测。
        let canonical = if frame.source.starts_with('/') {
            frame.source.clone()
        } else {
            match client.home_dir().await {
                Ok(home) => join_path(&home, &frame.source),
                Err(_) => frame.source.clone(),
            }
        };
        if !visited.insert(canonical) {
            continue;
        }

        // 先尝试读取目录；若失败再当作文件取元数据。
        match client.list_dir(&frame.source).await {
            Ok(entries) => {
                // 是目录。
                items.push(BatchItem {
                    source: frame.source.clone(),
                    destination: frame.dest.clone(),
                    size: 0,
                    is_dir: true,
                });

                for entry in entries {
                    // 跳过 . 与 ..
                    if entry.name == "." || entry.name == ".." {
                        continue;
                    }
                    let child_dest = join_path(&frame.dest, &entry.name);
                    stack.push(Frame {
                        source: entry.path,
                        dest: child_dest,
                        depth: frame.depth + 1,
                    });
                }
            }
            Err(_) => {
                // 当作文件处理；尝试获取元数据以累加 total_size。
                let size = client
                    .metadata(&frame.source)
                    .await
                    .ok()
                    .and_then(|m| m.size);
                if let Some(s) = size {
                    total_size += s;
                }
                items.push(BatchItem {
                    source: frame.source,
                    destination: frame.dest,
                    size: size.unwrap_or(0),
                    is_dir: false,
                });
            }
        }
    }

    Ok(BatchPlan { items, total_size })
}

/// 执行批量上传。
///
/// 按照 `plan` 中的项目顺序：创建远程目录、上传文件。遇到冲突时调用
/// `conflict_callback` 决策；未提供回调时默认覆盖。
/// 上传过程中通过 `progress` 回调报告累计已传字节与总字节数。
/// 用户可通过 `cancel` 标记取消任务。
pub async fn execute_batch_upload(
    client: &SftpClient,
    plan: &BatchPlan,
    options: &BatchTransferOptions,
    conflict_callback: Option<BatchConflictCallback>,
    progress: Option<BatchProgressCallback>,
    cancel: Option<Arc<AtomicBool>>,
) -> Result<BatchOutcome> {
    let mut outcome = BatchOutcome {
        completed: Vec::new(),
        skipped: Vec::new(),
        errors: Vec::new(),
        cancelled: false,
    };
    let mut transferred = 0u64;
    let total_size = plan.total_size;

    for item in &plan.items {
        if cancel
            .as_ref()
            .map(|c| c.load(Ordering::Relaxed))
            .unwrap_or(false)
        {
            outcome.cancelled = true;
            break;
        }

        if item.is_dir {
            if let Err(e) = client.create_dir_all(&item.destination).await {
                if options.stop_on_error {
                    return Err(e);
                }
                outcome
                    .errors
                    .push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
            continue;
        }

        let local = PathBuf::from(&item.source);
        let should_upload = if let Some(ref cb) = conflict_callback {
            match client
                .check_upload_conflict(&local, &item.destination)
                .await
            {
                Ok(Some(info)) => matches!(cb(item, &info), ConflictResolution::Overwrite),
                Ok(None) => true,
                Err(e) => {
                    if options.stop_on_error {
                        return Err(e);
                    }
                    outcome
                        .errors
                        .push(format!("{} -> {}: {}", item.source, item.destination, e));
                    continue;
                }
            }
        } else {
            true
        };

        if !should_upload {
            outcome.skipped.push(item.source.clone());
            continue;
        }

        let item_size = item.size;
        let progress_cb = progress.clone();
        let file_progress = progress_cb.map(|cb| {
            let cb = cb.clone();
            Arc::new(move |sent: u64, _total: u64| {
                cb(transferred + sent, total_size);
            }) as Arc<dyn Fn(u64, u64) + Send + Sync>
        });

        match client
            .upload_with_cancel(&local, &item.destination, file_progress, cancel.clone())
            .await
        {
            Ok(()) => {
                transferred += item_size;
                outcome.completed.push(item.source.clone());
            }
            Err(Error::Cancelled) => {
                outcome.cancelled = true;
                break;
            }
            Err(e) => {
                if options.stop_on_error {
                    return Err(e);
                }
                outcome
                    .errors
                    .push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
        }
    }

    Ok(outcome)
}

/// 执行批量下载。
///
/// 按照 `plan` 中的项目顺序：创建本地目录、下载文件。遇到冲突时调用
/// `conflict_callback` 决策；未提供回调时默认覆盖。
pub async fn execute_batch_download(
    client: &SftpClient,
    plan: &BatchPlan,
    options: &BatchTransferOptions,
    conflict_callback: Option<BatchConflictCallback>,
    progress: Option<BatchProgressCallback>,
    cancel: Option<Arc<AtomicBool>>,
) -> Result<BatchOutcome> {
    let mut outcome = BatchOutcome {
        completed: Vec::new(),
        skipped: Vec::new(),
        errors: Vec::new(),
        cancelled: false,
    };
    let mut transferred = 0u64;
    let total_size = plan.total_size;

    for item in &plan.items {
        if cancel
            .as_ref()
            .map(|c| c.load(Ordering::Relaxed))
            .unwrap_or(false)
        {
            outcome.cancelled = true;
            break;
        }

        if item.is_dir {
            let local = PathBuf::from(&item.destination);
            if let Err(e) = tokio::fs::create_dir_all(&local).await {
                if options.stop_on_error {
                    return Err(e.into());
                }
                outcome
                    .errors
                    .push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
            continue;
        }

        let local = PathBuf::from(&item.destination);
        // 确保父目录存在。
        if let Some(parent) = local.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }

        let should_download = if let Some(ref cb) = conflict_callback {
            match client.check_download_conflict(&item.source, &local).await {
                Ok(Some(info)) => matches!(cb(item, &info), ConflictResolution::Overwrite),
                Ok(None) => true,
                Err(e) => {
                    if options.stop_on_error {
                        return Err(e);
                    }
                    outcome
                        .errors
                        .push(format!("{} -> {}: {}", item.source, item.destination, e));
                    continue;
                }
            }
        } else {
            true
        };

        if !should_download {
            outcome.skipped.push(item.source.clone());
            continue;
        }

        let item_size = item.size;
        let progress_cb = progress.clone();
        let file_progress = progress_cb.map(|cb| {
            let cb = cb.clone();
            Arc::new(move |received: u64, _total: u64| {
                cb(transferred + received, total_size);
            }) as Arc<dyn Fn(u64, u64) + Send + Sync>
        });

        match client
            .download_with_cancel(&item.source, &local, file_progress, cancel.clone())
            .await
        {
            Ok(()) => {
                transferred += item_size;
                outcome.completed.push(item.source.clone());
            }
            Err(Error::Cancelled) => {
                outcome.cancelled = true;
                break;
            }
            Err(e) => {
                if options.stop_on_error {
                    return Err(e);
                }
                outcome
                    .errors
                    .push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
        }
    }

    Ok(outcome)
}

// ---------------------------------------------------------------------------
// 批量传输任务服务
// ---------------------------------------------------------------------------

/// 批量传输方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BatchDirection {
    Upload,
    Download,
}

/// 批量传输任务状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchStatus {
    Queued,
    Running,
    WaitingForConflict,
    Completed,
    Failed,
    Cancelled,
}

impl BatchStatus {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            BatchStatus::Completed | BatchStatus::Failed | BatchStatus::Cancelled
        )
    }
}

/// 批量传输中单个文件冲突的快照。
#[derive(Debug, Clone)]
pub struct BatchConflictInfo {
    pub item_source: String,
    pub item_destination: String,
    pub source_size: u64,
    pub source_mtime: Option<u64>,
    pub target_size: u64,
    pub target_mtime: Option<u64>,
}

/// 批量传输任务快照。
#[derive(Debug, Clone)]
pub struct BatchTaskSnapshot {
    pub id: String,
    pub direction: BatchDirection,
    pub host_id: String,
    pub dest_dir: String,
    pub sources: Vec<String>,
    pub total_size: u64,
    pub transferred: u64,
    pub status: BatchStatus,
    pub error: Option<String>,
    pub pending_conflict: Option<BatchConflictInfo>,
}

/// 冲突决策通道：由服务构造，注入执行器上下文。
///
/// 调用 `resolve` 时，任务状态进入 `WaitingForConflict`，等待外部决策或超时。
#[derive(Clone)]
pub struct BatchConflictResolver {
    inner: Arc<ConflictResolverInner>,
}

struct ConflictResolverInner {
    pending_conflict: Mutex<Option<BatchConflictInfo>>,
    status: Mutex<BatchStatus>,
    timeout: Duration,
    decision_tx: Mutex<Option<tokio::sync::oneshot::Sender<ConflictResolution>>>,
}

impl BatchConflictResolver {
    fn new(timeout: Duration) -> Self {
        Self {
            inner: Arc::new(ConflictResolverInner {
                pending_conflict: Mutex::new(None),
                status: Mutex::new(BatchStatus::Queued),
                timeout,
                decision_tx: Mutex::new(None),
            }),
        }
    }

    /// 等待外部对冲突的决策；超时按跳过处理。
    pub fn resolve(&self) -> Pin<Box<dyn Future<Output = ConflictResolution> + Send>> {
        let inner = self.inner.clone();
        Box::pin(async move {
            let rx = {
                let (tx, rx) = tokio::sync::oneshot::channel();
                *inner.decision_tx.lock().unwrap() = Some(tx);
                rx
            };
            match tokio::time::timeout(inner.timeout, rx).await {
                Ok(Ok(resolution)) => resolution,
                _ => ConflictResolution::Skip,
            }
        })
    }

    pub fn set_pending(&self, info: BatchConflictInfo) {
        *self.inner.pending_conflict.lock().unwrap() = Some(info);
        *self.inner.status.lock().unwrap() = BatchStatus::WaitingForConflict;
    }

    pub fn clear_pending(&self) {
        *self.inner.pending_conflict.lock().unwrap() = None;
        *self.inner.decision_tx.lock().unwrap() = None;
    }

    fn send_decision(&self, resolution: ConflictResolution) -> bool {
        let tx = self.inner.decision_tx.lock().unwrap().take();
        if let Some(tx) = tx {
            tx.send(resolution).is_ok()
        } else {
            false
        }
    }

    fn is_waiting(&self) -> bool {
        *self.inner.status.lock().unwrap() == BatchStatus::WaitingForConflict
    }

    fn pending_conflict(&self) -> Option<BatchConflictInfo> {
        self.inner.pending_conflict.lock().unwrap().clone()
    }

    fn status(&self) -> BatchStatus {
        *self.inner.status.lock().unwrap()
    }

    fn set_status(&self, status: BatchStatus) {
        *self.inner.status.lock().unwrap() = status;
    }
}

/// 批量传输执行器 trait：由调用方注入实际扫描与传输逻辑。
pub trait BatchExecutor: Send + Sync + 'static {
    fn execute(
        &self,
        ctx: &BatchContext,
    ) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>>;
}

/// 执行器上下文：提供进度回报、取消检测与冲突决策通道，以及任务元数据。
pub struct BatchContext {
    pub progress: Arc<dyn Fn(u64, u64) + Send + Sync>,
    pub cancel: Arc<AtomicBool>,
    pub conflict: BatchConflictResolver,
    pub direction: BatchDirection,
    pub host_id: String,
    pub sources: Vec<String>,
    pub dest_dir: String,
    pub password: Option<String>,
    pub passphrase: Option<String>,
}

/// 批量传输服务：管理任务注册表、状态转换、冲突超时与取消。
pub struct BatchTransferService {
    inner: Arc<BatchServiceInner>,
}

struct BatchServiceInner {
    tasks: Mutex<HashMap<Uuid, Arc<BatchTaskEntry>>>,
    executor: Box<dyn BatchExecutor>,
    conflict_timeout: Duration,
    change_counter: AtomicU64,
    on_change: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl BatchServiceInner {
    fn notify_changed(&self) {
        self.change_counter.fetch_add(1, Ordering::Relaxed);
        if let Some(ref cb) = self.on_change {
            cb();
        }
    }
}

struct BatchTaskEntry {
    id: Uuid,
    direction: BatchDirection,
    host_id: String,
    dest_dir: String,
    sources: Vec<String>,
    password: Option<String>,
    passphrase: Option<String>,
    total_size: AtomicU64,
    transferred: AtomicU64,
    error: Mutex<Option<String>>,
    cancel: Arc<AtomicBool>,
    resolver: BatchConflictResolver,
}

impl BatchTaskEntry {
    fn snapshot(&self) -> BatchTaskSnapshot {
        BatchTaskSnapshot {
            id: self.id.to_string(),
            direction: self.direction,
            host_id: self.host_id.clone(),
            dest_dir: self.dest_dir.clone(),
            sources: self.sources.clone(),
            total_size: self.total_size.load(Ordering::Relaxed),
            transferred: self.transferred.load(Ordering::Relaxed),
            status: self.resolver.status(),
            error: self.error.lock().unwrap().clone(),
            pending_conflict: self.resolver.pending_conflict(),
        }
    }
}

/// 创建批量传输服务的参数。
pub struct BatchServiceParams {
    pub conflict_timeout: Duration,
    pub on_change: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl Default for BatchServiceParams {
    fn default() -> Self {
        Self {
            conflict_timeout: Duration::from_secs(300),
            on_change: None,
        }
    }
}

impl BatchTransferService {
    pub fn new(executor: Box<dyn BatchExecutor>) -> Self {
        Self::with_params(executor, BatchServiceParams::default())
    }

    pub fn with_params(executor: Box<dyn BatchExecutor>, params: BatchServiceParams) -> Self {
        Self {
            inner: Arc::new(BatchServiceInner {
                tasks: Mutex::new(HashMap::new()),
                executor,
                conflict_timeout: params.conflict_timeout,
                change_counter: AtomicU64::new(0),
                on_change: params.on_change,
            }),
        }
    }

    pub fn start_upload(
        &self,
        host_id: String,
        sources: Vec<String>,
        dest_dir: String,
        password: Option<String>,
        passphrase: Option<String>,
    ) -> Result<String> {
        self.start_task(BatchDirection::Upload, host_id, sources, dest_dir, password, passphrase)
    }

    pub fn start_download(
        &self,
        host_id: String,
        sources: Vec<String>,
        dest_dir: String,
        password: Option<String>,
        passphrase: Option<String>,
    ) -> Result<String> {
        self.start_task(BatchDirection::Download, host_id, sources, dest_dir, password, passphrase)
    }

    fn start_task(
        &self,
        direction: BatchDirection,
        host_id: String,
        sources: Vec<String>,
        dest_dir: String,
        password: Option<String>,
        passphrase: Option<String>,
    ) -> Result<String> {
        let id = Uuid::new_v4();
        let resolver = BatchConflictResolver::new(self.inner.conflict_timeout);
        let entry = Arc::new(BatchTaskEntry {
            id,
            direction,
            host_id,
            dest_dir,
            sources,
            password,
            passphrase,
            total_size: AtomicU64::new(0),
            transferred: AtomicU64::new(0),
            error: Mutex::new(None),
            cancel: Arc::new(AtomicBool::new(false)),
            resolver,
        });
        self.inner
            .tasks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, entry.clone());
        self.inner.notify_changed();

        let inner = self.inner.clone();
        tokio::spawn(async move {
            run_batch_task(inner, entry).await;
        });
        Ok(id.to_string())
    }

    pub fn status(&self, task_id: &str) -> Result<BatchTaskSnapshot> {
        let id = Uuid::parse_str(task_id)
            .map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let tasks = self.inner.tasks.lock().unwrap();
        let entry = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        Ok(entry.snapshot())
    }

    pub fn list(&self) -> Vec<BatchTaskSnapshot> {
        let tasks = self.inner.tasks.lock().unwrap();
        let mut snapshots: Vec<_> = tasks.values().map(|t| t.snapshot()).collect();
        snapshots.sort_by(|a, b| a.id.cmp(&b.id));
        snapshots
    }

    pub fn cancel(&self, task_id: &str) -> Result<()> {
        let id = Uuid::parse_str(task_id)
            .map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let tasks = self.inner.tasks.lock().unwrap();
        let entry = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        entry.cancel.store(true, Ordering::Relaxed);
        if entry.resolver.is_waiting() {
            entry
                .resolver
                .send_decision(ConflictResolution::Skip);
            entry.resolver.clear_pending();
        }
        self.inner.notify_changed();
        Ok(())
    }

    pub fn resolve_conflict(
        &self,
        task_id: &str,
        overwrite: bool,
    ) -> Result<()> {
        let id = Uuid::parse_str(task_id)
            .map_err(|e| Error::Other(format!("无效任务 id: {e}")))?;
        let tasks = self.inner.tasks.lock().unwrap();
        let entry = tasks
            .get(&id)
            .ok_or_else(|| Error::Other(format!("未知任务: {task_id}")))?;
        if !entry.resolver.is_waiting() {
            return Err(Error::Other("任务不在等待冲突状态".to_string()));
        }
        let resolution = if overwrite {
            ConflictResolution::Overwrite
        } else {
            ConflictResolution::Skip
        };
        entry.resolver.send_decision(resolution);
        entry.resolver.clear_pending();
        self.inner.notify_changed();
        Ok(())
    }

    pub fn change_counter(&self) -> u64 {
        self.inner.change_counter.load(Ordering::Relaxed)
    }
}

impl Clone for BatchTransferService {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

async fn run_batch_task(inner: Arc<BatchServiceInner>, entry: Arc<BatchTaskEntry>) {
    if entry.cancel.load(Ordering::Relaxed) {
        entry.resolver.set_status(BatchStatus::Cancelled);
        inner.notify_changed();
        return;
    }
    entry.resolver.set_status(BatchStatus::Running);
    inner.notify_changed();

    let progress = {
        let entry = entry.clone();
        let inner_ref = inner.clone();
        Arc::new(move |done: u64, total: u64| {
            entry.transferred.store(done, Ordering::Relaxed);
            if total > 0 {
                entry.total_size.store(total, Ordering::Relaxed);
            }
            inner_ref.notify_changed();
        }) as Arc<dyn Fn(u64, u64) + Send + Sync>
    };

    let ctx = BatchContext {
        progress,
        cancel: entry.cancel.clone(),
        conflict: entry.resolver.clone(),
        direction: entry.direction,
        host_id: entry.host_id.clone(),
        sources: entry.sources.clone(),
        dest_dir: entry.dest_dir.clone(),
        password: entry.password.clone(),
        passphrase: entry.passphrase.clone(),
    };

    let outcome = inner.executor.execute(&ctx).await;

    if outcome.cancelled || entry.cancel.load(Ordering::Relaxed) {
        entry.resolver.set_status(BatchStatus::Cancelled);
    } else if !outcome.errors.is_empty() {
        entry.resolver.set_status(BatchStatus::Failed);
        *entry.error.lock().unwrap() = Some(outcome.errors.join("; "));
    } else {
        entry.resolver.set_status(BatchStatus::Completed);
        entry
            .transferred
            .store(entry.total_size.load(Ordering::Relaxed), Ordering::Relaxed);
    }
    entry.resolver.clear_pending();
    inner.notify_changed();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> ScanOptions {
        ScanOptions::default()
    }

    #[tokio::test]
    async fn scan_single_local_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.txt");
        tokio::fs::write(&file, b"hello").await.unwrap();

        let plan = scan_local_sources(&[file.clone()], "/remote", &opts())
            .await
            .unwrap();

        assert_eq!(plan.items.len(), 1);
        assert_eq!(plan.items[0].source, file.to_string_lossy().to_string());
        assert_eq!(plan.items[0].destination, "/remote/a.txt");
        assert_eq!(plan.items[0].size, 5);
        assert_eq!(plan.items[0].is_dir, false);
        assert_eq!(plan.total_size, 5);
    }

    #[tokio::test]
    async fn scan_local_directory_recursively() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("project");
        tokio::fs::create_dir(&src).await.unwrap();
        tokio::fs::write(src.join("README.md"), b"readme")
            .await
            .unwrap();
        let sub = src.join("src");
        tokio::fs::create_dir(&sub).await.unwrap();
        tokio::fs::write(sub.join("main.swift"), b"code")
            .await
            .unwrap();

        let plan = scan_local_sources(&[src.clone()], "/remote", &opts())
            .await
            .unwrap();

        assert_eq!(plan.items.len(), 4); // project dir, README, src dir, main.swift
        assert_eq!(plan.total_size, 10);

        let destinations: Vec<_> = plan.items.iter().map(|i| i.destination.clone()).collect();
        assert!(destinations.contains(&"/remote/project".to_string()));
        assert!(destinations.contains(&"/remote/project/README.md".to_string()));
        assert!(destinations.contains(&"/remote/project/src".to_string()));
        assert!(destinations.contains(&"/remote/project/src/main.swift".to_string()));
    }

    #[tokio::test]
    async fn scan_empty_local_directory() {
        let dir = tempfile::tempdir().unwrap();
        let empty = dir.path().join("empty");
        tokio::fs::create_dir(&empty).await.unwrap();

        let plan = scan_local_sources(&[empty.clone()], "/remote", &opts())
            .await
            .unwrap();

        assert_eq!(plan.items.len(), 1);
        assert_eq!(plan.items[0].destination, "/remote/empty");
        assert!(plan.items[0].is_dir);
        assert_eq!(plan.total_size, 0);
    }

    #[tokio::test]
    async fn scan_multiple_local_sources() {
        let dir = tempfile::tempdir().unwrap();
        let file1 = dir.path().join("a.txt");
        let dir1 = dir.path().join("folder");
        tokio::fs::write(&file1, b"a").await.unwrap();
        tokio::fs::create_dir(&dir1).await.unwrap();
        tokio::fs::write(dir1.join("b.txt"), b"bb").await.unwrap();

        let plan = scan_local_sources(&[file1.clone(), dir1.clone()], "/remote", &opts())
            .await
            .unwrap();

        let destinations: Vec<_> = plan.items.iter().map(|i| i.destination.clone()).collect();
        assert!(destinations.contains(&"/remote/a.txt".to_string()));
        assert!(destinations.contains(&"/remote/folder".to_string()));
        assert!(destinations.contains(&"/remote/folder/b.txt".to_string()));
        assert_eq!(plan.total_size, 3);
    }

    #[tokio::test]
    async fn scan_local_skips_symlink_loop_when_following() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a");
        tokio::fs::create_dir(&a).await.unwrap();
        tokio::fs::write(a.join("file.txt"), b"x").await.unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            symlink(&a, a.join("loop")).unwrap();
        }

        let opts = ScanOptions {
            follow_symlinks: true,
            ..Default::default()
        };
        let plan = scan_local_sources(&[a.clone()], "/remote", &opts)
            .await
            .unwrap();

        // 应包含 a 目录与 file.txt，但不进入 loop 指向的内容。
        let destinations: Vec<_> = plan.items.iter().map(|i| i.destination.clone()).collect();
        assert!(destinations.contains(&"/remote/a".to_string()));
        assert!(destinations.contains(&"/remote/a/file.txt".to_string()));
        assert!(destinations.contains(&"/remote/a/loop".to_string()));
        assert_eq!(plan.total_size, 1);
    }

    #[tokio::test]
    async fn scan_local_respects_max_depth() {
        let dir = tempfile::tempdir().unwrap();
        let d1 = dir.path().join("d1");
        tokio::fs::create_dir(&d1).await.unwrap();
        let d2 = d1.join("d2");
        tokio::fs::create_dir(&d2).await.unwrap();
        let d3 = d2.join("d3");
        tokio::fs::create_dir(&d3).await.unwrap();
        tokio::fs::write(d3.join("deep.txt"), b"deep")
            .await
            .unwrap();

        let opts = ScanOptions {
            max_depth: 2,
            ..Default::default()
        };
        let result = scan_local_sources(&[d1.clone()], "/remote", &opts).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn scan_local_empty_sources_returns_empty_plan() {
        let plan = scan_local_sources(&[], "/remote", &opts()).await.unwrap();
        assert!(plan.items.is_empty());
        assert_eq!(plan.total_size, 0);
    }

    #[tokio::test]
    async fn scan_local_source_with_trailing_slash_dest() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x.txt");
        tokio::fs::write(&file, b"x").await.unwrap();

        let plan = scan_local_sources(&[file], "/remote/", &opts())
            .await
            .unwrap();
        assert_eq!(plan.items[0].destination, "/remote/x.txt");
    }

    #[tokio::test]
    async fn scan_local_follows_symlink_to_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("target.txt");
        tokio::fs::write(&file, b"linked").await.unwrap();
        let link = dir.path().join("link.txt");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&file, &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&file, &link).unwrap();

        let opts = ScanOptions {
            follow_symlinks: true,
            ..Default::default()
        };
        let plan = scan_local_sources(&[link.clone()], "/remote", &opts)
            .await
            .unwrap();

        assert_eq!(plan.items.len(), 1);
        assert_eq!(plan.items[0].source, link.to_string_lossy().to_string());
        assert_eq!(plan.items[0].destination, "/remote/link.txt");
        assert_eq!(plan.items[0].size, 6);
        assert!(!plan.items[0].is_dir);
        assert_eq!(plan.total_size, 6);
    }

    #[tokio::test]
    async fn scan_local_broken_symlink_uses_link_size() {
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("broken");
        #[cfg(unix)]
        std::os::unix::fs::symlink("missing", &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file("missing", &link).unwrap();

        let opts = ScanOptions {
            follow_symlinks: true,
            ..Default::default()
        };
        let plan = scan_local_sources(&[link.clone()], "/remote", &opts)
            .await
            .unwrap();

        assert_eq!(plan.items.len(), 1);
        assert_eq!(plan.items[0].source, link.to_string_lossy().to_string());
        assert!(!plan.items[0].is_dir);
        // 跟随失败时回退到链接自身大小（即目标路径字符串长度）。
        assert_eq!(plan.items[0].size, 7);
    }

    #[test]
    fn join_path_handles_trailing_slash() {
        assert_eq!(join_path("/remote", "file.txt"), "/remote/file.txt");
        assert_eq!(join_path("/remote/", "file.txt"), "/remote/file.txt");
        assert_eq!(join_path("/remote", ""), "/remote");
    }
}

#[cfg(test)]
mod batch_service_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct FakeExecutor {
        outcome: BatchOutcome,
        delay: Duration,
    }

    impl FakeExecutor {
        fn success() -> Self {
            Self {
                outcome: BatchOutcome {
                    completed: vec!["a".into()],
                    skipped: vec![],
                    errors: vec![],
                    cancelled: false,
                },
                delay: Duration::from_millis(10),
            }
        }

        fn with_outcome(outcome: BatchOutcome) -> Self {
            Self {
                outcome,
                delay: Duration::from_millis(10),
            }
        }
    }

    impl BatchExecutor for FakeExecutor {
        fn execute(
            &self,
            _ctx: &BatchContext,
        ) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
            let outcome = self.outcome.clone();
            let delay = self.delay;
            Box::pin(async move {
                tokio::time::sleep(delay).await;
                outcome
            })
        }
    }

    struct ConflictExecutor {
        conflicts: Arc<AtomicUsize>,
    }

    impl ConflictExecutor {
        fn new() -> Self {
            Self {
                conflicts: Arc::new(AtomicUsize::new(0)),
            }
        }
    }

    impl BatchExecutor for ConflictExecutor {
        fn execute(
            &self,
            ctx: &BatchContext,
        ) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
            let conflict = ctx.conflict.clone();
            let cancel = ctx.cancel.clone();
            let progress = ctx.progress.clone();
            let conflicts = self.conflicts.clone();
            Box::pin(async move {
                progress(0, 100);
                loop {
                    if cancel.load(Ordering::Relaxed) {
                        return BatchOutcome {
                            completed: vec![],
                            skipped: vec![],
                            errors: vec![],
                            cancelled: true,
                        };
                    }
                    let n = conflicts.fetch_add(1, Ordering::Relaxed);
                    if n >= 3 {
                        break;
                    }
                    conflict.set_pending(BatchConflictInfo {
                        item_source: format!("src{n}.txt"),
                        item_destination: format!("dst{n}.txt"),
                        source_size: 10,
                        source_mtime: None,
                        target_size: 5,
                        target_mtime: None,
                    });
                    let resolution = conflict.resolve().await;
                    if !conflict.is_waiting()
                        && conflict.status() == BatchStatus::WaitingForConflict
                    {
                    }
                    if matches!(resolution, ConflictResolution::Overwrite) {
                        break;
                    }
                }
                progress(100, 100);
                BatchOutcome {
                    completed: vec!["done".into()],
                    skipped: vec![],
                    errors: vec![],
                    cancelled: false,
                }
            })
        }
    }

    fn params_with_timeout(secs: u64) -> BatchServiceParams {
        BatchServiceParams {
            conflict_timeout: Duration::from_secs(secs),
            on_change: None,
        }
    }

    // ---- 正常流程 ----

    #[tokio::test]
    async fn start_upload_runs_to_completion() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id = svc
            .start_upload("h1".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Completed);
        assert_eq!(snap.direction, BatchDirection::Upload);
        assert_eq!(snap.host_id, "h1");
        assert_eq!(snap.dest_dir, "/d");
        assert_eq!(snap.sources, vec!["s".to_string()]);
    }

    #[tokio::test]
    async fn start_download_runs_to_completion() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id = svc
            .start_download("h2".into(), vec!["r".into()], "/local".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Completed);
        assert_eq!(snap.direction, BatchDirection::Download);
    }

    #[tokio::test]
    async fn conflict_overwrite_resolution() {
        let svc = BatchTransferService::with_params(
            Box::new(ConflictExecutor::new()),
            params_with_timeout(300),
        );
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        let mut waited = false;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let snap = svc.status(&id).unwrap();
            if snap.status == BatchStatus::WaitingForConflict {
                waited = true;
                break;
            }
        }
        assert!(waited, "task should enter WaitingForConflict");

        let snap = svc.status(&id).unwrap();
        assert!(snap.pending_conflict.is_some());
        assert_eq!(
            snap.pending_conflict.as_ref().unwrap().item_source,
            "src0.txt"
        );

        svc.resolve_conflict(&id, true).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Completed);
        assert!(snap.pending_conflict.is_none());
    }

    #[tokio::test]
    async fn conflict_skip_then_completes() {
        let exec = ConflictExecutor::new();
        let svc =
            BatchTransferService::with_params(Box::new(exec), params_with_timeout(300));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if svc.status(&id).unwrap().status == BatchStatus::WaitingForConflict {
                break;
            }
        }
        svc.resolve_conflict(&id, false).unwrap();

        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if svc.status(&id).unwrap().status == BatchStatus::WaitingForConflict {
                break;
            }
        }
        svc.resolve_conflict(&id, true).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(svc.status(&id).unwrap().status, BatchStatus::Completed);
    }

    #[tokio::test]
    async fn error_isolation_records_failure() {
        let outcome = BatchOutcome {
            completed: vec!["ok".into()],
            skipped: vec![],
            errors: vec!["file.txt: permission denied".into()],
            cancelled: false,
        };
        let svc = BatchTransferService::new(Box::new(FakeExecutor::with_outcome(outcome)));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Failed);
        assert!(snap.error.as_ref().unwrap().contains("permission denied"));
    }

    #[tokio::test]
    async fn on_change_callback_fires() {
        let counter = Arc::new(AtomicU64::new(0));
        let params = BatchServiceParams {
            conflict_timeout: Duration::from_secs(300),
            on_change: Some({
                let counter = counter.clone();
                Arc::new(move || {
                    counter.fetch_add(1, Ordering::Relaxed);
                })
            }),
        };
        let svc = BatchTransferService::with_params(Box::new(FakeExecutor::success()), params);
        let _id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(counter.load(Ordering::Relaxed) >= 2);
    }

    #[tokio::test]
    async fn list_orders_by_id() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id_a = svc
            .start_upload("h".into(), vec!["a".into()], "/d".into(), None, None)
            .unwrap();
        let id_b = svc
            .start_upload("h".into(), vec!["b".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let list = svc.list();
        let ids: Vec<_> = list.iter().map(|s| s.id.clone()).collect();
        assert!(ids.contains(&id_a));
        assert!(ids.contains(&id_b));
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted, "list should be sorted by id");
    }

    // ---- 意外/错误 ----

    #[tokio::test]
    async fn connection_failure_marks_failed() {
        let outcome = BatchOutcome {
            completed: vec![],
            skipped: vec![],
            errors: vec!["SSH 连接失败: 拒绝连接".into()],
            cancelled: false,
        };
        let svc = BatchTransferService::new(Box::new(FakeExecutor::with_outcome(outcome)));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Failed);
        assert!(snap.error.unwrap().contains("拒绝连接"));
    }

    #[tokio::test]
    async fn item_failure_records_error_and_continues() {
        let outcome = BatchOutcome {
            completed: vec!["ok.txt".into()],
            skipped: vec![],
            errors: vec!["bad.txt: 写入失败".into()],
            cancelled: false,
        };
        let svc = BatchTransferService::new(Box::new(FakeExecutor::with_outcome(outcome)));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Failed);
        assert!(snap.error.unwrap().contains("写入失败"));
    }

    #[tokio::test]
    async fn resolve_conflict_when_not_waiting_returns_error() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let result = svc.resolve_conflict(&id, true);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn resolve_conflict_unknown_task_returns_error() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let fake_id = Uuid::new_v4().to_string();
        let result = svc.resolve_conflict(&fake_id, true);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn status_unknown_task_returns_error() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        assert!(svc.status("not-a-uuid").is_err());
        assert!(svc.status(&Uuid::new_v4().to_string()).is_err());
    }

    #[tokio::test]
    async fn cancel_unknown_task_returns_error() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        assert!(svc.cancel("garbage").is_err());
        assert!(svc.cancel(&Uuid::new_v4().to_string()).is_err());
    }

    // ---- 边界 ----

    #[tokio::test]
    async fn empty_sources_still_runs_executor() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id = svc
            .start_upload("h".into(), vec![], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Completed);
        assert!(snap.sources.is_empty());
    }

    #[tokio::test]
    async fn conflict_timeout_defaults_to_skip() {
        let exec = ConflictExecutor::new();
        let svc =
            BatchTransferService::with_params(Box::new(exec), params_with_timeout(0));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        tokio::time::sleep(Duration::from_millis(50)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Completed);
        assert!(snap.pending_conflict.is_none());
    }

    #[tokio::test]
    async fn cancel_before_start_marks_cancelled() {
        let gate = Arc::new(tokio::sync::Notify::new());
        struct GatedExecutor {
            gate: Arc<tokio::sync::Notify>,
        }
        impl BatchExecutor for GatedExecutor {
            fn execute(
                &self,
                ctx: &BatchContext,
            ) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
                let gate = self.gate.clone();
                let cancel = ctx.cancel.clone();
                Box::pin(async move {
                    gate.notified().await;
                    if cancel.load(Ordering::Relaxed) {
                        BatchOutcome {
                            completed: vec![],
                            skipped: vec![],
                            errors: vec![],
                            cancelled: true,
                        }
                    } else {
                        BatchOutcome {
                            completed: vec!["ok".into()],
                            skipped: vec![],
                            errors: vec![],
                            cancelled: false,
                        }
                    }
                })
            }
        }

        let svc = BatchTransferService::new(Box::new(GatedExecutor {
            gate: gate.clone(),
        }));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        tokio::time::sleep(Duration::from_millis(10)).await;
        svc.cancel(&id).unwrap();
        gate.notify_one();
        tokio::time::sleep(Duration::from_millis(100)).await;

        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Cancelled);
    }

    #[tokio::test]
    async fn cancel_during_conflict_wait_sends_skip() {
        let exec = ConflictExecutor::new();
        let svc =
            BatchTransferService::with_params(Box::new(exec), params_with_timeout(300));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if svc.status(&id).unwrap().status == BatchStatus::WaitingForConflict {
                break;
            }
        }
        assert_eq!(
            svc.status(&id).unwrap().status,
            BatchStatus::WaitingForConflict
        );

        svc.cancel(&id).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.status, BatchStatus::Cancelled);
        assert!(snap.pending_conflict.is_none());
    }

    #[tokio::test]
    async fn consecutive_conflicts_resolve_independently() {
        let exec = ConflictExecutor::new();
        let svc =
            BatchTransferService::with_params(Box::new(exec), params_with_timeout(300));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();

        for expected_src in ["src0.txt", "src1.txt"] {
            for _ in 0..50 {
                tokio::time::sleep(Duration::from_millis(10)).await;
                if svc.status(&id).unwrap().status == BatchStatus::WaitingForConflict {
                    break;
                }
            }
            let snap = svc.status(&id).unwrap();
            assert_eq!(snap.status, BatchStatus::WaitingForConflict);
            assert_eq!(
                snap.pending_conflict.as_ref().unwrap().item_source,
                expected_src
            );
            svc.resolve_conflict(&id, false).unwrap();
        }

        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if svc.status(&id).unwrap().status == BatchStatus::WaitingForConflict {
                break;
            }
        }
        svc.resolve_conflict(&id, true).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(svc.status(&id).unwrap().status, BatchStatus::Completed);
    }

    #[tokio::test]
    async fn progress_callback_updates_transferred() {
        struct ProgressExecutor;
        impl BatchExecutor for ProgressExecutor {
            fn execute(
                &self,
                ctx: &BatchContext,
            ) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
                let progress = ctx.progress.clone();
                Box::pin(async move {
                    progress(50, 100);
                    tokio::time::sleep(Duration::from_millis(5)).await;
                    progress(100, 100);
                    BatchOutcome {
                        completed: vec!["ok".into()],
                        skipped: vec![],
                        errors: vec![],
                        cancelled: false,
                    }
                })
            }
        }

        let svc = BatchTransferService::new(Box::new(ProgressExecutor));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.transferred, 100);
        assert_eq!(snap.total_size, 100);
    }

    #[tokio::test]
    async fn change_counter_increments_on_transitions() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let before = svc.change_counter();
        let _id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let after = svc.change_counter();
        assert!(after > before);
    }

    #[tokio::test]
    async fn list_empty_service_returns_empty() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        assert!(svc.list().is_empty());
    }

    #[tokio::test]
    async fn cancelled_outcome_sets_cancelled_status() {
        let outcome = BatchOutcome {
            completed: vec![],
            skipped: vec![],
            errors: vec![],
            cancelled: true,
        };
        let svc = BatchTransferService::new(Box::new(FakeExecutor::with_outcome(outcome)));
        let id = svc
            .start_upload("h".into(), vec!["s".into()], "/d".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(svc.status(&id).unwrap().status, BatchStatus::Cancelled);
    }

    #[tokio::test]
    async fn snapshot_contains_all_fields() {
        let svc = BatchTransferService::new(Box::new(FakeExecutor::success()));
        let id = svc
            .start_upload("host-abc".into(), vec!["x".into(), "y".into()], "/dest".into(), None, None)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let snap = svc.status(&id).unwrap();
        assert_eq!(snap.id, id);
        assert_eq!(snap.direction, BatchDirection::Upload);
        assert_eq!(snap.host_id, "host-abc");
        assert_eq!(snap.dest_dir, "/dest");
        assert_eq!(snap.sources, vec!["x".to_string(), "y".to_string()]);
        assert_eq!(snap.status, BatchStatus::Completed);
        assert!(snap.error.is_none());
        assert!(snap.pending_conflict.is_none());
    }

    #[tokio::test]
    async fn batch_status_is_terminal() {
        assert!(!BatchStatus::Queued.is_terminal());
        assert!(!BatchStatus::Running.is_terminal());
        assert!(!BatchStatus::WaitingForConflict.is_terminal());
        assert!(BatchStatus::Completed.is_terminal());
        assert!(BatchStatus::Failed.is_terminal());
        assert!(BatchStatus::Cancelled.is_terminal());
    }
}
