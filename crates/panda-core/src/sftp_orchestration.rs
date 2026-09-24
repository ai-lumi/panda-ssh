//! SFTP 编排规划：将扫描+聚合结果转为入队计划。
//!
//! 调用方提交选中路径、扫描结果和方向；本模块按既有分组规则
//! （见 `task_aggregation`）产出统一逐文件计划；两个方向共享组标识与目录准备，
//! 目录本身不是文件任务，空目录也保留显式组记录。

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

/// 目录组计划；目录准备不是文件任务。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedGroup {
    pub group_id: String,
    pub name: String,
    pub source_root: String,
    pub destination_root: String,
    pub directories: Vec<TaskItem>,
}

/// 编排结果；旧批量字段仅供尚未迁移的消费者编译。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SftpOrchestrationPlan {
    pub transfers: Vec<PlannedTransfer>,
    pub groups: Vec<PlannedGroup>,
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
/// - 两个方向：目录组内每个文件 → 独立传输（共享 group_id）；独立文件 → 无组传输
/// - 每个顶层目录保留完整根路径和父目录在先的逐路径准备计划
pub fn plan_sftp_orchestration(
    selected_paths: &[String],
    items: &[TaskItem],
    direction: SftpOrchestrationDirection,
) -> SftpOrchestrationPlan {
    if selected_paths.is_empty() || items.is_empty() {
        return SftpOrchestrationPlan {
            transfers: vec![],
            groups: vec![],
            batches: vec![],
        };
    }

    let aggregation = aggregate_task_groups(
        selected_paths,
        items,
        match direction {
            SftpOrchestrationDirection::Upload => {
                crate::task_aggregation::TransferDirection::Upload
            }
            SftpOrchestrationDirection::Download => {
                crate::task_aggregation::TransferDirection::Download
            }
        },
    );

    let mut plan = SftpOrchestrationPlan {
        transfers: vec![],
        groups: vec![],
        batches: vec![],
    };

    for group in &aggregation.groups {
        plan.groups.push(PlannedGroup {
            group_id: group.id.clone(),
            name: group.name.clone(),
            source_root: group.source_root.clone(),
            destination_root: group.destination_root.clone(),
            directories: group.directories.clone(),
        });
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

/// 扫描本地选择一次，并复用其文件及目录数据生成统一计划。
pub async fn scan_local_orchestration(
    sources: &[String],
    destination_dir: &str,
    options: &crate::batch::ScanOptions,
) -> crate::Result<SftpOrchestrationPlan> {
    let paths: Vec<_> = sources.iter().map(std::path::PathBuf::from).collect();
    let scan = crate::batch::scan_local_sources(&paths, destination_dir, options).await?;
    Ok(plan_from_scan(
        sources,
        scan,
        SftpOrchestrationDirection::Upload,
    ))
}

/// 扫描远程选择一次；适配器不得执行目标端写入。
pub async fn scan_remote_orchestration<R: crate::batch::RemoteSourceScanner + ?Sized>(
    scanner: &R,
    sources: &[String],
    destination_dir: &str,
    options: &crate::batch::ScanOptions,
) -> crate::Result<SftpOrchestrationPlan> {
    let scan =
        crate::batch::scan_remote_sources(scanner, sources, destination_dir, options).await?;
    Ok(plan_from_scan(
        sources,
        scan,
        SftpOrchestrationDirection::Download,
    ))
}

fn plan_from_scan(
    sources: &[String],
    scan: crate::batch::BatchPlan,
    direction: SftpOrchestrationDirection,
) -> SftpOrchestrationPlan {
    let items: Vec<_> = scan
        .items
        .into_iter()
        .map(|item| TaskItem {
            name: item
                .source
                .rsplit('/')
                .next()
                .unwrap_or(&item.source)
                .to_string(),
            source: item.source,
            destination: item.destination,
            size: item.size,
            is_dir: item.is_dir,
        })
        .collect();
    plan_sftp_orchestration(sources, &items, direction)
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

    #[test]
    fn unified_plan_four_selection_modes_in_both_directions() {
        for direction in [
            SftpOrchestrationDirection::Upload,
            SftpOrchestrationDirection::Download,
        ] {
            for (sources, expected_files, expected_groups) in [
                (vec!["/source/x"], 1, 0),
                (vec!["/source/A"], 2, 1),
                (vec!["/source/x", "/source/y"], 2, 0),
                (
                    vec!["/source/A", "/source/B", "/source/x", "/source/y"],
                    5,
                    2,
                ),
                (vec![], 0, 0),
            ] {
                let selected: Vec<String> = sources.into_iter().map(str::to_owned).collect();
                let items = vec![
                    dir_item("/source/A", "/target/A"),
                    file_item("/source/A/0", "/target/A/0", 0),
                    dir_item("/source/A/sub", "/target/A/sub"),
                    file_item("/source/A/sub/1", "/target/A/sub/1", 1),
                    dir_item("/source/B", "/target/B"),
                    file_item("/source/B/2", "/target/B/2", 2),
                    file_item("/source/x", "/target/x", 3),
                    file_item("/source/y", "/target/y", 4),
                ];
                let plan = plan_sftp_orchestration(&selected, &items, direction);
                assert_eq!(plan.transfers.len(), expected_files);
                assert_eq!(plan.groups.len(), expected_groups);
                assert!(plan.batches.is_empty());
                for file in &plan.transfers {
                    let original = items.iter().find(|i| i.source == file.source).unwrap();
                    assert_eq!(file.destination, original.destination);
                    assert_eq!(file.size, original.size);
                    if file.source == "/source/x" || file.source == "/source/y" {
                        assert!(file.group_id.is_none());
                    } else {
                        assert!(plan
                            .groups
                            .iter()
                            .any(|g| Some(&g.group_id) == file.group_id.as_ref()));
                    }
                }
            }
        }
    }

    #[test]
    fn unified_plan_preserves_empty_directories_and_never_merges_same_names() {
        let selected = vec!["/a/中文 空间".into(), "/b/中文 空间".into()];
        let items = vec![
            dir_item("/a/中文 空间", "/target/中文 空间"),
            dir_item("/b/中文 空间", "/target/中文 空间"),
            dir_item("/b/中文 空间/empty/sub", "/target/中文 空间/empty/sub"),
            dir_item("/b/中文 空间/empty", "/target/中文 空间/empty"),
            file_item("/a/中文 空间/零 字节", "/target/中文 空间/零 字节", 0),
        ];
        for direction in [
            SftpOrchestrationDirection::Upload,
            SftpOrchestrationDirection::Download,
        ] {
            let plan = plan_sftp_orchestration(&selected, &items, direction);
            assert_eq!(plan.groups.len(), 2);
            assert_eq!(plan.transfers.len(), 1);
            assert!(plan.batches.is_empty());
            assert_eq!(plan.groups[0].source_root, "/a/中文 空间");
            assert_eq!(plan.groups[1].source_root, "/b/中文 空间");
            assert_eq!(plan.groups[1].destination_root, "/target/中文 空间");
            assert_eq!(
                plan.groups[1]
                    .directories
                    .iter()
                    .map(|i| i.source.as_str())
                    .collect::<Vec<_>>(),
                vec![
                    "/b/中文 空间",
                    "/b/中文 空间/empty",
                    "/b/中文 空间/empty/sub"
                ]
            );
            assert_ne!(plan.groups[0].group_id, plan.groups[1].group_id);
            assert_eq!(
                plan.transfers[0].group_id.as_ref(),
                Some(&plan.groups[0].group_id)
            );
            let next = plan_sftp_orchestration(&selected, &items, direction);
            assert_ne!(plan.groups[0].group_id, next.groups[0].group_id);
        }
    }

    #[test]
    fn unified_plan_overlap_and_duplicate_items_enqueue_once() {
        let selected = vec![
            "/source/A".into(),
            "/source/A".into(),
            "/source/A/sub".into(),
            "/source/A/sub/file".into(),
            "/source/free".into(),
            "/source/free".into(),
        ];
        let mut items = vec![
            dir_item("/source/A", "/target/A"),
            dir_item("/source/A/sub", "/target/A/sub"),
            file_item("/source/A/sub/file", "/target/A/sub/file", 0),
            file_item("/source/free", "/target/free", 0),
        ];
        items.extend(items.clone());
        for direction in [
            SftpOrchestrationDirection::Upload,
            SftpOrchestrationDirection::Download,
        ] {
            let plan = plan_sftp_orchestration(&selected, &items, direction);
            assert_eq!(plan.transfers.len(), 2);
            assert_eq!(plan.groups.len(), 1);
            assert_eq!(plan.groups[0].directories.len(), 2);
            assert_eq!(
                plan.transfers
                    .iter()
                    .filter(|t| t.group_id.is_none())
                    .count(),
                1
            );
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
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].source, "/remote/file.txt");
        assert_eq!(plan.transfers[0].destination, "/local/file.txt");
        assert!(plan.transfers[0].group_id.is_none());
    }

    #[test]
    fn upload_directory_returns_file_tasks_and_group() {
        let selected = vec!["/local/dirA".to_string()];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_item("/local/dirA/f2.txt", "/remote/dirA/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 2);
        assert!(plan.batches.is_empty());
        assert_eq!(plan.groups.len(), 1);
        assert_eq!(plan.groups[0].name, "dirA");
        assert_eq!(plan.groups[0].source_root, "/local/dirA");
    }

    #[test]
    fn download_directory_returns_individual_transfers_with_shared_group() {
        let selected = vec!["/remote/dirA".to_string()];
        let items = vec![
            dir_item("/remote/dirA", "/local/dirA"),
            file_item("/remote/dirA/f1.txt", "/local/dirA/f1.txt", 100),
            file_item("/remote/dirA/f2.txt", "/local/dirA/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
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
        let selected = vec!["/local/dirA".to_string(), "/local/readme.md".to_string()];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_item("/local/readme.md", "/remote/readme.md", 50),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.transfers.len(), 2);
        let standalone = plan
            .transfers
            .iter()
            .find(|t| t.source == "/local/readme.md")
            .unwrap();
        assert!(standalone.group_id.is_none());
        assert!(plan.batches.is_empty());
        assert_eq!(plan.groups.len(), 1);
        assert_eq!(plan.groups[0].name, "dirA");
    }

    #[test]
    fn mixed_files_and_directories_download() {
        let selected = vec!["/remote/dirA".to_string(), "/remote/readme.md".to_string()];
        let items = vec![
            dir_item("/remote/dirA", "/local/dirA"),
            file_item("/remote/dirA/f1.txt", "/local/dirA/f1.txt", 100),
            file_item("/remote/readme.md", "/local/readme.md", 50),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
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
    fn multiple_directories_upload_returns_multiple_groups() {
        let selected = vec!["/local/dirA".to_string(), "/local/dirB".to_string()];
        let items = vec![
            dir_item("/local/dirA", "/remote/dirA"),
            file_item("/local/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            dir_item("/local/dirB", "/remote/dirB"),
            file_item("/local/dirB/f2.txt", "/remote/dirB/f2.txt", 200),
        ];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.groups.len(), 2);
        assert_eq!(plan.transfers.len(), 2);
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn multiple_standalone_files_upload() {
        let selected = vec!["/local/f1.txt".to_string(), "/local/f2.txt".to_string()];
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
        assert_eq!(plan.groups.len(), 1);
        assert_eq!(plan.groups[0].name, "project");
        assert!(plan.batches.is_empty());
    }

    #[test]
    fn empty_directory_upload_produces_group_with_source() {
        let selected = vec!["/local/empty_dir".to_string()];
        let items = vec![dir_item("/local/empty_dir", "/remote/empty_dir")];
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Upload);
        assert_eq!(plan.groups.len(), 1);
        assert_eq!(plan.groups[0].source_root, "/local/empty_dir");
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
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
        let plan = plan_sftp_orchestration(&selected, &items, SftpOrchestrationDirection::Download);
        assert!(plan.transfers.is_empty());
        assert!(plan.batches.is_empty());
    }
}
