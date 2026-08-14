//! 批量 SFTP 传输：递归扫描本地/远程目录，生成批量传输计划。

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

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
            dest: join_path(dest_dir, source.file_name().and_then(|n| n.to_str()).unwrap_or("")),
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
                let child_dest = join_path(&frame.dest, entry.file_name().to_string_lossy().as_ref());
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
    if name.is_empty() {
        dir.to_string()
    } else if dir.ends_with('/') {
        format!("{}{}", dir, name)
    } else {
        format!("{}/{}", dir, name)
    }
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
                let size = client.metadata(&frame.source).await.ok().and_then(|m| m.size);
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
        if cancel.as_ref().map(|c| c.load(Ordering::Relaxed)).unwrap_or(false) {
            outcome.cancelled = true;
            break;
        }

        if item.is_dir {
            if let Err(e) = client.create_dir_all(&item.destination).await {
                if options.stop_on_error {
                    return Err(e);
                }
                outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
            continue;
        }

        let local = PathBuf::from(&item.source);
        let should_upload = if let Some(ref cb) = conflict_callback {
            match client.check_upload_conflict(&local, &item.destination).await {
                Ok(Some(info)) => matches!(cb(item, &info), ConflictResolution::Overwrite),
                Ok(None) => true,
                Err(e) => {
                    if options.stop_on_error {
                        return Err(e);
                    }
                    outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
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
                outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
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
        if cancel.as_ref().map(|c| c.load(Ordering::Relaxed)).unwrap_or(false) {
            outcome.cancelled = true;
            break;
        }

        if item.is_dir {
            let local = PathBuf::from(&item.destination);
            if let Err(e) = tokio::fs::create_dir_all(&local).await {
                if options.stop_on_error {
                    return Err(e.into());
                }
                outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
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
                    outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
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
                outcome.errors.push(format!("{} -> {}: {}", item.source, item.destination, e));
            }
        }
    }

    Ok(outcome)
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
        tokio::fs::write(src.join("README.md"), b"readme").await.unwrap();
        let sub = src.join("src");
        tokio::fs::create_dir(&sub).await.unwrap();
        tokio::fs::write(sub.join("main.swift"), b"code").await.unwrap();

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
        tokio::fs::write(d3.join("deep.txt"), b"deep").await.unwrap();

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

        let plan = scan_local_sources(&[file], "/remote/", &opts()).await.unwrap();
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
