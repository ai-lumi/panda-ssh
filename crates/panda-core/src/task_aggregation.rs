//! 任务聚合：将扁平的扫描结果按 spec 规则分组为任务组。
//!
//! 分组规则（见 openspec/specs/sftp-batch-transfer）：
//! - 每个选中的顶层目录 → 一个任务组
//! - 目录内递归展开的文件 → 组内独立任务
//! - 子目录本身不作为子任务组
//! - 仅选中多个文件时 → 无组的独立任务

use uuid::Uuid;

/// 传输方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferDirection {
    Upload,
    Download,
    Delete,
}

/// 任务组内的单个文件任务。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskItem {
    /// 源路径。
    pub source: String,
    /// 目标路径。
    pub destination: String,
    /// 文件大小（字节）。
    pub size: u64,
    /// 显示名称。
    pub name: String,
    /// 是否为目录项。
    pub is_dir: bool,
}

/// 任务组：一个顶层目录对应的聚合单元。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskGroup {
    /// 组唯一标识。
    pub id: String,
    /// 组名（顶层目录名）。
    pub name: String,
    /// 传输方向。
    pub direction: TransferDirection,
    /// 组内文件任务列表。
    pub items: Vec<TaskItem>,
}

/// 聚合结果：任务组列表 + 无组的独立任务列表。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AggregationResult {
    /// 按顶层目录生成的任务组。
    pub groups: Vec<TaskGroup>,
    /// 不属于任何目录的独立文件任务。
    pub standalone_items: Vec<TaskItem>,
}

/// 任务状态（用于聚合状态计算）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskStatus {
    Queued,
    Running,
    Paused,
    Done,
    Failed,
    Cancelled,
}

impl TaskGroup {
    /// 组内所有文件的总字节数。
    pub fn total_size(&self) -> u64 {
        self.items.iter().map(|item| item.size).sum()
    }

    /// 聚合进度：给定每个 item 的已传输字节查询函数，返回 0..=1.0 的进度值。
    pub fn aggregate_progress(&self, transferred: &dyn Fn(&str) -> u64) -> f64 {
        let total = self.total_size();
        if total == 0 {
            return 1.0;
        }
        let done: u64 = self
            .items
            .iter()
            .map(|item| transferred(&item.source))
            .sum();
        (done as f64 / total as f64).min(1.0)
    }

    /// 聚合状态：按 running > paused > queued > failed > cancelled > done 优先级。
    pub fn aggregate_status(&self, status_of: &dyn Fn(&str) -> TaskStatus) -> TaskStatus {
        let statuses: Vec<TaskStatus> = self
            .items
            .iter()
            .map(|item| status_of(&item.source))
            .collect();
        if statuses.is_empty() {
            return TaskStatus::Done;
        }
        let status_set = |s: TaskStatus| statuses.contains(&s);
        if status_set(TaskStatus::Running) {
            return TaskStatus::Running;
        }
        if status_set(TaskStatus::Paused) {
            return TaskStatus::Paused;
        }
        if status_set(TaskStatus::Queued) {
            return TaskStatus::Queued;
        }
        if status_set(TaskStatus::Failed) {
            return TaskStatus::Failed;
        }
        if status_set(TaskStatus::Cancelled) {
            return TaskStatus::Cancelled;
        }
        TaskStatus::Done
    }
}

/// 将扁平扫描结果按 spec 规则聚合为任务组。
///
/// - `selected_paths`: 用户选中的顶层路径（文件与目录混合）
/// - `all_items`: 扫描后的扁平项目列表（含目录项与文件项）
/// - `direction`: 传输方向
pub fn aggregate_task_groups(
    selected_paths: &[String],
    all_items: &[TaskItem],
    direction: TransferDirection,
) -> AggregationResult {
    // 1. 找出选中的顶层目录（排除被其他选中目录包含的子目录）
    let selected_dir_paths: Vec<&str> = selected_paths
        .iter()
        .filter(|path| {
            all_items
                .iter()
                .any(|item| item.source == **path && item.is_dir)
        })
        .map(|s| s.as_str())
        .collect();

    let top_level_dirs = filter_top_level_dirs(&selected_dir_paths);

    // 2. 找出选中的文件中不属于任何选中目录的文件
    let standalone: Vec<TaskItem> = selected_paths
        .iter()
        .filter(|path| {
            !all_items
                .iter()
                .any(|item| item.source == **path && item.is_dir)
        })
        .filter(|path| {
            !top_level_dirs
                .iter()
                .any(|dir| is_descendant_of(path.as_str(), dir))
        })
        .filter_map(|path| all_items.iter().find(|item| item.source == *path).cloned())
        .collect();

    // 3. 为每个顶层目录构建任务组
    let groups: Vec<TaskGroup> = top_level_dirs
        .iter()
        .map(|dir_path| {
            let group_name = extract_name(dir_path);
            let items: Vec<TaskItem> = all_items
                .iter()
                .filter(|item| {
                    !item.is_dir
                        && (item.source == *dir_path || is_descendant_of(&item.source, dir_path))
                })
                .cloned()
                .collect();
            TaskGroup {
                id: Uuid::new_v4().to_string(),
                name: group_name,
                direction,
                items,
            }
        })
        .collect();

    AggregationResult {
        groups,
        standalone_items: standalone,
    }
}

/// 组级取消计划：返回组内所有非终态任务的源路径。
pub fn group_cancel_plan(group: &TaskGroup) -> Vec<String> {
    group.items.iter().map(|item| item.source.clone()).collect()
}

/// 组级重试计划：返回组内所有失败任务的源路径。
/// 需要外部提供每个 item 的当前状态。
pub fn group_retry_plan(group: &TaskGroup, status_of: &dyn Fn(&str) -> TaskStatus) -> Vec<String> {
    group
        .items
        .iter()
        .filter(|item| status_of(&item.source) == TaskStatus::Failed)
        .map(|item| item.source.clone())
        .collect()
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

fn filter_top_level_dirs<'a>(dirs: &[&'a str]) -> Vec<&'a str> {
    dirs.iter()
        .copied()
        .filter(|dir| {
            !dirs
                .iter()
                .copied()
                .any(|other| other != *dir && is_descendant_of(*dir, other))
        })
        .collect()
}

fn is_descendant_of(path: &str, ancestor: &str) -> bool {
    path.starts_with(&format!("{}/", ancestor.trim_end_matches('/')))
}

fn extract_name(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_item(source: &str, dest: &str, size: u64) -> TaskItem {
        TaskItem {
            source: source.to_string(),
            destination: dest.to_string(),
            size,
            name: extract_name(source),
            is_dir: false,
        }
    }

    fn dir_item(source: &str, dest: &str) -> TaskItem {
        TaskItem {
            source: source.to_string(),
            destination: dest.to_string(),
            size: 0,
            name: extract_name(source),
            is_dir: true,
        }
    }

    // === 1.2 分组规则测试 ===

    #[test]
    fn multiple_dirs_produce_multiple_groups() {
        let selected = vec!["/a/dirA".to_string(), "/a/dirB".to_string()];
        let items = vec![
            dir_item("/a/dirA", "/remote/dirA"),
            file_item("/a/dirA/file1.txt", "/remote/dirA/file1.txt", 100),
            dir_item("/a/dirB", "/remote/dirB"),
            file_item("/a/dirB/file2.txt", "/remote/dirB/file2.txt", 200),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 2);
        assert_eq!(result.standalone_items.len(), 0);
    }

    #[test]
    fn files_only_no_groups() {
        let selected = vec!["/a/file1.txt".to_string(), "/a/file2.txt".to_string()];
        let items = vec![
            file_item("/a/file1.txt", "/remote/file1.txt", 100),
            file_item("/a/file2.txt", "/remote/file2.txt", 200),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 0);
        assert_eq!(result.standalone_items.len(), 2);
    }

    #[test]
    fn empty_input_returns_empty() {
        let result = aggregate_task_groups(&[], &[], TransferDirection::Download);
        assert_eq!(result.groups.len(), 0);
        assert_eq!(result.standalone_items.len(), 0);
    }

    // === 1.3 分组规则测试 ===

    #[test]
    fn subdirs_do_not_become_subgroups() {
        let selected = vec!["/a/project".to_string()];
        let items = vec![
            dir_item("/a/project", "/remote/project"),
            dir_item("/a/project/src", "/remote/project/src"),
            file_item(
                "/a/project/src/main.swift",
                "/remote/project/src/main.swift",
                300,
            ),
            file_item("/a/project/README.md", "/remote/project/README.md", 100),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 1);
        assert_eq!(result.groups[0].name, "project");
        assert!(result.groups[0]
            .items
            .iter()
            .all(|i| !i.source.ends_with("/src")));
        assert_eq!(result.groups[0].items.len(), 2);
    }

    #[test]
    fn mixed_dirs_and_files() {
        let selected = vec!["/a/dirA".to_string(), "/a/readme.md".to_string()];
        let items = vec![
            dir_item("/a/dirA", "/remote/dirA"),
            file_item("/a/dirA/file1.txt", "/remote/dirA/file1.txt", 100),
            file_item("/a/readme.md", "/remote/readme.md", 50),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 1);
        assert_eq!(result.groups[0].name, "dirA");
        assert_eq!(result.standalone_items.len(), 1);
        assert_eq!(result.standalone_items[0].source, "/a/readme.md");
    }

    #[test]
    fn dir_with_only_subdirs_no_files_produces_empty_group() {
        let selected = vec!["/a/empty_dir".to_string()];
        let items = vec![
            dir_item("/a/empty_dir", "/remote/empty_dir"),
            dir_item("/a/empty_dir/sub", "/remote/empty_dir/sub"),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 1);
        assert_eq!(result.groups[0].items.len(), 0);
    }

    // === 1.5 顶层目录识别测试 ===

    #[test]
    fn nested_selection_only_outermost_dir() {
        let selected = vec!["/a/project".to_string(), "/a/project/src".to_string()];
        let items = vec![
            dir_item("/a/project", "/remote/project"),
            dir_item("/a/project/src", "/remote/project/src"),
            file_item(
                "/a/project/src/main.swift",
                "/remote/project/src/main.swift",
                300,
            ),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Upload);
        assert_eq!(result.groups.len(), 1);
        assert_eq!(result.groups[0].name, "project");
    }

    // === 2.1 total_size 测试 ===

    #[test]
    fn total_size_normal() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 200),
            ],
        };
        assert_eq!(group.total_size(), 300);
    }

    #[test]
    fn total_size_empty_group() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![],
        };
        assert_eq!(group.total_size(), 0);
    }

    // === 2.2 aggregate_progress 测试 ===

    #[test]
    fn progress_partial() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 100),
            ],
        };
        let transferred = |src: &str| -> u64 {
            if src == "/a/f1.txt" {
                100
            } else {
                0
            }
        };
        let progress = group.aggregate_progress(&transferred);
        assert!((progress - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn progress_all_done() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![file_item("/a/f1.txt", "/remote/f1.txt", 100)],
        };
        let transferred = |_src: &str| -> u64 { 100 };
        assert!((group.aggregate_progress(&transferred) - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn progress_zero_total_returns_one() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![],
        };
        let transferred = |_src: &str| -> u64 { 0 };
        assert!((group.aggregate_progress(&transferred) - 1.0).abs() < f64::EPSILON);
    }

    // === 2.3 aggregate_status 测试 ===

    #[test]
    fn status_running_highest_priority() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 100),
            ],
        };
        let status_of = |src: &str| -> TaskStatus {
            if src == "/a/f1.txt" {
                TaskStatus::Running
            } else {
                TaskStatus::Failed
            }
        };
        assert_eq!(group.aggregate_status(&status_of), TaskStatus::Running);
    }

    #[test]
    fn status_all_done() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![file_item("/a/f1.txt", "/remote/f1.txt", 100)],
        };
        let status_of = |_src: &str| -> TaskStatus { TaskStatus::Done };
        assert_eq!(group.aggregate_status(&status_of), TaskStatus::Done);
    }

    #[test]
    fn status_mixed_failed_and_cancelled() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 100),
            ],
        };
        let status_of = |src: &str| -> TaskStatus {
            if src == "/a/f1.txt" {
                TaskStatus::Failed
            } else {
                TaskStatus::Cancelled
            }
        };
        assert_eq!(group.aggregate_status(&status_of), TaskStatus::Failed);
    }

    // === 3.1 group_cancel_plan 测试 ===

    #[test]
    fn cancel_plan_returns_all_sources() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 200),
            ],
        };
        let plan = group_cancel_plan(&group);
        assert_eq!(plan, vec!["/a/f1.txt", "/a/f2.txt"]);
    }

    #[test]
    fn cancel_plan_empty_group() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![],
        };
        let plan = group_cancel_plan(&group);
        assert!(plan.is_empty());
    }

    // === 3.2 group_retry_plan 测试 ===

    #[test]
    fn retry_plan_returns_failed_sources() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![
                file_item("/a/f1.txt", "/remote/f1.txt", 100),
                file_item("/a/f2.txt", "/remote/f2.txt", 200),
                file_item("/a/f3.txt", "/remote/f3.txt", 300),
            ],
        };
        let status_of = |src: &str| -> TaskStatus {
            match src {
                "/a/f1.txt" => TaskStatus::Done,
                "/a/f2.txt" => TaskStatus::Failed,
                "/a/f3.txt" => TaskStatus::Failed,
                _ => TaskStatus::Done,
            }
        };
        let plan = group_retry_plan(&group, &status_of);
        assert_eq!(plan, vec!["/a/f2.txt", "/a/f3.txt"]);
    }

    #[test]
    fn retry_plan_no_failures() {
        let group = TaskGroup {
            id: "g1".to_string(),
            name: "test".to_string(),
            direction: TransferDirection::Upload,
            items: vec![file_item("/a/f1.txt", "/remote/f1.txt", 100)],
        };
        let status_of = |_src: &str| -> TaskStatus { TaskStatus::Done };
        let plan = group_retry_plan(&group, &status_of);
        assert!(plan.is_empty());
    }

    // === 4.1 Delete 方向测试 ===

    #[test]
    fn delete_direction_same_grouping_rules() {
        let selected = vec!["/a/dirA".to_string(), "/a/file.txt".to_string()];
        let items = vec![
            dir_item("/a/dirA", "/remote/dirA"),
            file_item("/a/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_item("/a/file.txt", "/remote/file.txt", 50),
        ];
        let result = aggregate_task_groups(&selected, &items, TransferDirection::Delete);
        assert_eq!(result.groups.len(), 1);
        assert_eq!(result.groups[0].direction, TransferDirection::Delete);
        assert_eq!(result.standalone_items.len(), 1);
    }
}
