use panda_ffi::{
    aggregate_task_groups_ffi, AggregationResultRecord, BatchTransferDirectionEnum,
    TaskGroupRecord, TaskItemRecord,
};

fn file_item(source: &str, dest: &str, size: u64) -> TaskItemRecord {
    TaskItemRecord {
        source: source.to_string(),
        destination: dest.to_string(),
        size,
        name: source.rsplit('/').next().unwrap_or(source).to_string(),
        is_dir: false,
    }
}

fn dir_item(source: &str, dest: &str) -> TaskItemRecord {
    TaskItemRecord {
        source: source.to_string(),
        destination: dest.to_string(),
        size: 0,
        name: source.rsplit('/').next().unwrap_or(source).to_string(),
        is_dir: true,
    }
}

#[test]
fn aggregate_returns_groups_for_selected_dirs() {
    let selected = vec!["/a/dirA".to_string(), "/a/dirB".to_string()];
    let items = vec![
        dir_item("/a/dirA", "/remote/dirA"),
        file_item("/a/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
        dir_item("/a/dirB", "/remote/dirB"),
        file_item("/a/dirB/f2.txt", "/remote/dirB/f2.txt", 200),
    ];
    let result = aggregate_task_groups_ffi(selected, items, BatchTransferDirectionEnum::Upload);
    assert_eq!(result.groups.len(), 2);
    assert_eq!(result.standalone_items.len(), 0);
    assert_eq!(result.groups[0].total_size, 100);
    assert_eq!(result.groups[1].total_size, 200);
}

#[test]
fn aggregate_empty_input_returns_empty() {
    let result = aggregate_task_groups_ffi(
        vec![],
        vec![],
        BatchTransferDirectionEnum::Download,
    );
    assert_eq!(result.groups.len(), 0);
    assert_eq!(result.standalone_items.len(), 0);
}

#[test]
fn aggregate_files_only_no_groups() {
    let selected = vec!["/a/f1.txt".to_string(), "/a/f2.txt".to_string()];
    let items = vec![
        file_item("/a/f1.txt", "/remote/f1.txt", 100),
        file_item("/a/f2.txt", "/remote/f2.txt", 200),
    ];
    let result = aggregate_task_groups_ffi(selected, items, BatchTransferDirectionEnum::Upload);
    assert_eq!(result.groups.len(), 0);
    assert_eq!(result.standalone_items.len(), 2);
}

#[test]
fn aggregate_mixed_dirs_and_files() {
    let selected = vec!["/a/dirA".to_string(), "/a/readme.md".to_string()];
    let items = vec![
        dir_item("/a/dirA", "/remote/dirA"),
        file_item("/a/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
        file_item("/a/readme.md", "/remote/readme.md", 50),
    ];
    let result = aggregate_task_groups_ffi(selected, items, BatchTransferDirectionEnum::Upload);
    assert_eq!(result.groups.len(), 1);
    assert_eq!(result.groups[0].name, "dirA");
    assert_eq!(result.standalone_items.len(), 1);
}
