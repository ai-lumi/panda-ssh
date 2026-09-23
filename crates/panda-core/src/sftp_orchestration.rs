//! SFTP 编排规划：将扫描+聚合结果转为入队计划。
//!
//! 调用方提交选中路径、扫描结果和方向；本模块按既有分组规则
//! （见 `task_aggregation`）产出入队计划：独立文件走单文件传输，
//! 目录组走批量传输（上传）或共享组标识的独立传输（下载）。

use crate::task_aggregation::{aggregate_task_groups, TaskItem};

/// 编排方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SftpOrchestrationDirection {
    Upload,
    Download,
}

/// 计划中的单个传输任务。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedTransfer {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub name: String,
    pub group_id: Option<String>,
    pub group_name: Option<String>,
}

/// 计划中的批量传输（一个目录组对应一个批量任务）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedBatch {
    pub group_id: String,
    pub group_name: String,
    pub sources: Vec<String>,
}

/// 编排结果：独立传输列表 + 批量传输列表。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SftpOrchestrationPlan {
    pub transfers: Vec<PlannedTransfer>,
    pub batches: Vec<PlannedBatch>,
}

/// 将扫描+聚合结果转为入队计划。
///
/// - `selected_paths`: 用户选中的顶层路径
/// - `items`: 扫描后的扁平项目列表
/// - `direction`: 传输方向
///
/// 规则：
/// - 空输入返回空计划
/// - 单个文件（无目录）→ 单个传输
/// - 上传时：目录组 → 一个批量任务（单 SSH 连接复用）；独立文件 → 单个传输
/// - 下载时：目录组内每个文件 → 独立传输（共享 group_id）；独立文件 → 单个传输
pub fn plan_sftp_orchestration(
    selected_paths: &[String],
    items: &[TaskItem],
    direction: SftpOrchestrationDirection,
) -> SftpOrchestrationPlan {
    if selected_paths.is_empty() || items.is_empty() {
        return SftpOrchestrationPlan {
            transfers: vec![],
            batches: vec![],
        };
    }

    let aggregation = aggregate_task_groups(
        selected_paths,
        items,
        match direction {
            SftpOrchestrationDirection::Upload => crate::task_aggregation::TransferDirection::Upload,
            SftpOrchestrationDirection::Download => {
                crate::task_aggregation::TransferDirection::Download
            }
        },
    );

    let mut plan = SftpOrchestrationPlan {
        transfers: vec![],
        batches: vec![],
    };

    for group in &aggregation.groups {
        match direction {
            SftpOrchestrationDirection::Upload => {
                let sources: Vec<String> = selected_paths
                    .iter()
                    .filter(|path| {
                        items
                            .iter()
                            .any(|item| item.source == **path && item.is_dir)
                    })
                    .filter(|path| {
                        let name = path.rsplit('/').next().unwrap_or(path);
                        group.name == name
                    })
                    .cloned()
                    .collect();
                plan.batches.push(PlannedBatch {
                    group_id: group.id.clone(),
                    group_name: group.name.clone(),
                    sources,
                });
            }
            SftpOrchestrationDirection::Download => {
                for item in &group.items {
                    plan.transfers.push(PlannedTransfer {
                        source: item.source.clone(),
                        destination: item.destination.clone(),
                        size: item.size,
                        name: item.name.clone(),
                        group_id: Some(group.id.clone()),
                        group_name: Some(group.name.clone()),
                    });
                }
            }
        }
    }

    for item in &aggregation.standalone_items {
        plan.transfers.push(PlannedTransfer {
            source: item.source.clone(),
            destination: item.destination.clone(),
            size: item.size,
            name: item.name.clone(),
            group_id: None,
            group_name: None,
        });
    }

    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_item(source: &str, dest: &str, size: u64) -> TaskItem {
        TaskItem {
            source: source.to_string(),
            destination: dest.to_string(),
            size,
            name: source.rsplit('/').next().unwrap_or(source).to_string(),
            is_dir: false,
        }
    }

    fn dir_item(source: &str, dest: &str) -> TaskItem {
        TaskItem {
            source: source.to_string(),
            destination: dest.to_string(),
            size: 0,
            name: source.rsplit('/').next().unwrap_or(source).to_string(),
            is_dir: true,
        }
    }

    // === 正常流程 ===

    #[test]
    fn empty_input_returns_empty_plan() {
        let plan = plan_sftp_orchestration(&[], &[], SftpOrchestrationDirection::Upload);
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn single_file_upload_returns_one_transfer() {
        let selected = vec!["/local/file.txt".to_string()];
        let items = vec![file_item("/local/file.txt", "/remote/file.txt", 100)];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].source, "/local/file.txt");
        assert_eq!(plan.transfers[0].size, 100);
        assert!(plan.transfers[0].group_id.is_none());
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn single_file_download_returns_one_transfer() {
        let selected = vec!["/remote/file.txt".to_string()];
        let items = vec![file_item("/remote/file.txt", "/local/file.txt", 200)];
        let plan =
            plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].source, "/remote/file.txt");
        assert_eq!(plan.transfers[0].destination, "/local/file.txt");
        assert!(plan.transfers[0].group_id.is_none());
    }

    #[test]
    fn upload_directory_returns_one_batch() {
        let selected = vec!["/local/dirA".to_string()];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_item("/local/dirA/f2.txt", "/remote/dirA/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert!(plan.transfers.is_empty());
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].group_name, "dirA");
        assert_eq!(plan.batches[0].sources, vec!["/local/dirA"]);
    }

    #[test]
    fn download_directory_returns_individual_transfers_with_shared_group() {
        let selected = vec!["/remote/dirA".to_string()];
        let items = vec![
            dir_item("/remote/dirA", "/local/dirA"),
            file_item("/remote/dirA/f1.txt", "/local/dirA/f1.txt", 100),
            file_item("/remote/dirA/f2.txt", "/local/dirA/f2.txt", 200),
        ];
        let plan =
            plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert_eq!(plan.transfers.len(), 2);
        assert!(plan.batches.is_empty());
        let group_id = plan.transfers[0].group_id.as_ref().unwrap();
        assert!(!group_id.is_empty());
        for t in &plan.transfers {
            assert_eq!(t.group_id.as_ref().unwrap(), group_id);
            assert_eq!(t.group_name.as_ref().unwrap(), "dirA");
        }
    }

    #[test]
    fn mixed_files_and_directories_upload() {
        let selected = vec![
            "/local/dirA".to_string(),
            "/local/readme.md".to_string(),
        ];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_item("/local/readme.md", "/remote/readme.md", 50),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].source, "/local/readme.md");
        assert!(plan.transfers[0].group_id.is_none());
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].group_name, "dirA");
    }

    #[test]
    fn mixed_files_and_directories_download() {
        let selected = vec![
            "/remote/dirA".to_string(),
            "/remote/readme.md".to_string(),
        ];
        let items = vec![
            dir_item("/remote/dirA", "/local/dirA"),
            file_item("/remote/dirA/f1.txt", "/local/dirA/f1.txt", 100),
            file_item("/remote/readme.md", "/local/readme.md", 50),
        ];
        let plan =
            plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert_eq!(plan.transfers.len(), 2);
        let standalone = plan
            .transfers
            .iter()
            .find(|t| t.source == "/remote/readme.md")
            .unwrap();
        assert!(standalone.group_id.is_none());
        let grouped = plan
            .transfers
            .iter()
            .find(|t| t.source == "/remote/dirA/f1.txt")
            .unwrap();
        assert!(grouped.group_id.is_some());
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn multiple_directories_upload_returns_multiple_batches() {
        let selected = vec!["/local/dirA".to_string(), "/local/dirB".to_string()];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            dir_item("/local/dirB", "/remote/dirB"),
            file_item("/local/dirB/f2.txt", "/remote/dirB/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.batches.len(), 2);
        assert!(plan.transfers.is_empty());
    }

    #[test]
    fn multiple_standalone_files_upload() {
        let selected = vec![
            "/local/f1.txt".to_string(),
            "/local/f2.txt".to_string(),
        ];
        let items = vec![
            file_item("/local/f1.txt", "/remote/f1.txt", 100),
            file_item("/local/f2.txt", "/remote/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 2);
        assert!(plan.batches.is_empty());
    }

    // === 意外操作 ===

    #[test]
    fn selected_paths_not_in_items_returns_empty() {
        let selected = vec!["/local/missing.txt".to_string()];
        let items = vec![file_item("/local/other.txt", "/remote/other.txt", 100)];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn items_without_matching_selected_dirs_produces_no_groups() {
        let selected = vec!["/local/dirA".to_string()];
        let items = vec![file_item("/local/dirB/f1.txt", "/remote/dirB/f1.txt", 100)];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
    }

    // === 边界条件 ===

    #[test]
    fn nested_selection_only_outermost_dir() {
        let selected = vec![
            "/local/project".to_string(),
            "/local/project/src".to_string(),
        ];
        let items = vec![
            dir_item("/local/project", "/remote/project"),
            dir_item("/local/project/src", "/remote/project/src"),
            file_item(
                "/local/project/src/main.rs",
                "/remote/project/src/main.rs",
                300,
            ),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].group_name, "project");
    }

    #[test]
    fn empty_directory_upload_produces_batch_with_source() {
        let selected = vec!["/local/empty_dir".to_string()];
        let items = vec![dir_item("/local/empty_dir", "/remote/empty_dir")];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].sources, vec!["/local/empty_dir"]);
    }

    #[test]
    fn unicode_paths_preserved() {
        let selected = vec!["/本地/文件.txt".to_string()];
        let items = vec![file_item("/本地/文件.txt", "/远程/文件.txt", 100)];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].source, "/本地/文件.txt");
        assert_eq!(plan.transfers[0].name, "文件.txt");
    }

    #[test]
    fn same_name_different_directories() {
        let selected = vec![
            "/local/dirA/data.txt".to_string(),
            "/local/dirB/data.txt".to_string(),
        ];
        let items = vec![
            file_item("/local/dirA/data.txt", "/remote/dirA/data.txt", 100),
            file_item("/local/dirB/data.txt", "/remote/dirB/data.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 2);
        assert_ne!(plan.transfers[0].source, plan.transfers[1].source);
        assert_ne!(plan.transfers[0].destination, plan.transfers[1].destination);
    }

    #[test]
    fn download_empty_directory_produces_no_transfers() {
        let selected = vec!["/remote/empty".to_string()];
        let items = vec![dir_item("/remote/empty", "/local/empty")];
        let plan =
            plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
    }
}
