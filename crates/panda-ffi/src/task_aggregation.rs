//! 任务聚合的 FFI 导出。

use panda_core::{
    aggregate_task_groups, AggregationResult, TaskGroup, TaskItem, TransferDirection,
};

use super::BatchTransferDirectionEnum;

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// FFI-friendly 任务组内单个文件任务。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TaskItemRecord {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub name: String,
    pub is_dir: bool,
}

/// FFI-friendly 任务组。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TaskGroupRecord {
    pub id: String,
    pub name: String,
    pub direction: BatchTransferDirectionEnum,
    pub items: Vec<TaskItemRecord>,
    pub total_size: u64,
}

/// 聚合结果：任务组 + 独立文件。
#[derive(Debug, Clone, uniffi::Record)]
pub struct AggregationResultRecord {
    pub groups: Vec<TaskGroupRecord>,
    pub standalone_items: Vec<TaskItemRecord>,
}

// ---------------------------------------------------------------------------
// Conversion helpers
// ---------------------------------------------------------------------------

fn direction_from_ffi(dir: BatchTransferDirectionEnum) -> TransferDirection {
    match dir {
        BatchTransferDirectionEnum::Upload => TransferDirection::Upload,
        BatchTransferDirectionEnum::Download => TransferDirection::Download,
    }
}

fn item_to_record(item: &TaskItem) -> TaskItemRecord {
    TaskItemRecord {
        source: item.source.clone(),
        destination: item.destination.clone(),
        size: item.size,
        name: item.name.clone(),
        is_dir: item.is_dir,
    }
}

fn group_to_record(group: &TaskGroup) -> TaskGroupRecord {
    let direction = match group.direction {
        TransferDirection::Upload => BatchTransferDirectionEnum::Upload,
        TransferDirection::Download => BatchTransferDirectionEnum::Download,
        TransferDirection::Delete => BatchTransferDirectionEnum::Upload, // FFI 暂无 Delete，映射为 Upload
    };
    TaskGroupRecord {
        id: group.id.clone(),
        name: group.name.clone(),
        direction,
        items: group.items.iter().map(item_to_record).collect(),
        total_size: group.total_size(),
    }
}

fn result_to_record(result: &AggregationResult) -> AggregationResultRecord {
    AggregationResultRecord {
        groups: result.groups.iter().map(group_to_record).collect(),
        standalone_items: result.standalone_items.iter().map(item_to_record).collect(),
    }
}

fn item_from_record(record: &TaskItemRecord) -> TaskItem {
    TaskItem {
        source: record.source.clone(),
        destination: record.destination.clone(),
        size: record.size,
        name: record.name.clone(),
        is_dir: record.is_dir,
    }
}

// ---------------------------------------------------------------------------
// Public FFI API
// ---------------------------------------------------------------------------

/// 将扁平的扫描结果聚合为任务组。
#[uniffi::export]
pub fn aggregate_task_groups_ffi(
    selected_paths: Vec<String>,
    all_items: Vec<TaskItemRecord>,
    direction: BatchTransferDirectionEnum,
) -> AggregationResultRecord {
    let core_items: Vec<TaskItem> = all_items.iter().map(item_from_record).collect();
    let core_direction = direction_from_ffi(direction);
    let result = aggregate_task_groups(&selected_paths, &core_items, core_direction);
    result_to_record(&result)
}
