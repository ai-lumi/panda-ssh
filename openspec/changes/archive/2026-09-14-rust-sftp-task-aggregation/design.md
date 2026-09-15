## Context

当前 SFTP 批量传输存在两条并行路径：

- **Path A（Swift 侧逐文件任务组）**：`SftpSessionStore.upload/download` 调用 Rust 扫描得到扁平 `BatchItemRecord` 列表，然后在 Swift 中按目录边界分组，为每个文件创建独立 `TransferTask`（共享 `groupID`），每个文件独占一个 SSH 连接。
- **Path B（Rust 侧批量任务）**：`TransferStore.addBatchUpload/addBatchDownload` 将整个目录批次交给 Rust，Rust 内部用单 SSH 连接顺序传输所有文件，对外表现为一个聚合任务。

两条路径的分组规则（顶层目录 → 任务组、纯文件 → 无组）在 Swift 中硬编码，`TransferStore.taskGroups` 也自行按 `groupID` 聚合。这违反了「业务逻辑只落 Rust」原则，且批量删除等新能力会重复同样的分组逻辑。

## Goals / Non-Goals

**Goals:**

- 将分组规则、聚合进度计算、组级操作统一收口到 `panda-core` 的新模块
- FFI 暴露预聚合的任务组数据，Swift 不再自行计算分组
- 数据结构泛化，支持未来批量删除复用同一套聚合引擎
- 保持现有用户可见行为完全不变

**Non-Goals:**

- 不合并 Path A 和 Path B 的执行路径（连接策略差异大，属于后续独立变更）
- 不实现批量删除（仅预留扩展点）
- 不改变轮询、并发控制等已有机制

## Decisions

### 决策 1：新增纯函数式聚合模块 `task_aggregation.rs`

在 `crates/panda-core/src/task_aggregation.rs` 中实现无状态的聚合逻辑：

```rust
// 输入：扁平的扫描项列表 + 方向
// 输出：按 spec 规则分组的任务组列表
pub fn aggregate_task_groups(
    items: &[BatchItem],
    direction: TransferDirection,
) -> Vec<TaskGroup>
```

**分组规则**（已在 specs 中定义）：
- 每个选中的顶层目录 → 一个 `TaskGroup`
- 目录内递归展开的文件（`!is_dir`）→ 组内 `TaskItem`
- 子目录本身不作为子任务组
- 不属于任何顶层目录的顶层文件 → 无组的独立 `TaskItem`（`group_id = None`）

**替代方案**：把分组逻辑塞进现有 `BatchPlan`。否决——`BatchPlan` 是执行计划（扁平列表），分组是 UI 聚合视图，职责不同，不应耦合。

### 决策 2：`TaskGroup` 数据结构同时携带静态元数据和聚合进度

```rust
pub struct TaskGroup {
    pub id: String,           // UUID
    pub name: String,         // 目录名
    pub direction: TransferDirection,
    pub items: Vec<TaskItem>, // 组内文件任务
}

pub struct TaskItem {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub name: String,
}

impl TaskGroup {
    pub fn total_size(&self) -> u64;
    pub fn progress(&self, transferred: &dyn Fn(&str) -> u64) -> f64;
    pub fn aggregate_status(&self, statuses: &dyn Fn(&str) -> TaskStatus) -> TaskStatus;
}
```

进度和状态聚合是纯计算（给定各 item 的 transferred/status，算出组级值），放在 `TaskGroup` 的方法上。

**替代方案**：把 transferred 也存进 `TaskGroup` 字段。否决——transferred 是运行时动态值，由执行引擎更新，聚合模块只负责规则，不持有运行时状态。

### 决策 3：FFI 新增 `TaskGroupRecord` 和聚合查询函数

```rust
#[derive(uniffi::Record)]
pub struct TaskGroupRecord {
    pub id: String,
    pub name: String,
    pub direction: TransferDirectionEnum,
    pub items: Vec<TaskItemRecord>,
    pub total_size: u64,
}

#[derive(uniffi::Record)]
pub struct TaskItemRecord {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub name: String,
}
```

新增 FFI 函数：
- `aggregate_task_groups(items, direction) -> Vec<TaskGroupRecord>`：扫描后调用，返回预分组数据
- `cancel_task_group(group_id) -> ()`：组级取消（遍历组内任务设 cancel flag）
- `retry_task_group(group_id) -> ()`：组级重试（遍历组内失败任务重新入队）

### 决策 4：Swift 侧改造路径

1. `SftpSessionStore.upload/download`：扫描后调用 `aggregateTaskGroups()`（Rust FFI），拿到 `TaskGroupRecord` 列表，据此创建任务（目录 → 批量任务 or 带 groupID 的逐文件任务），不再自行判断目录/文件分组
2. `TransferStore.taskGroups`：改为直接消费 Rust 返回的组数据（通过轮询时从 Rust 获取 `TaskGroupRecord` 列表），删除 Swift 侧的 `Dictionary(grouping:)` 聚合逻辑
3. `TransferGroup` 结构体保留，但从 `TaskGroupRecord` 构造而非从 tasks 数组计算

### 决策 5：为批量删除预留扩展点

`TransferDirection` 枚举新增 `Delete` 变体（或在聚合模块中用泛型/trait 抽象方向）。`aggregate_task_groups` 的分组规则与方向无关（只看 items 的目录/文件边界），天然支持删除场景。

组级操作 `cancel_task_group` / `retry_task_group` 同样与方向无关，删除任务直接复用。

## Risks / Trade-offs

- **[风险] FFI 接口变更导致 Swift 侧大面积改动** → 迁移分两步走：先新增 Rust 模块和 FFI 函数（不改现有接口），再逐步切换 Swift 调用方。旧接口标记 deprecated，一个变更内完成迁移。
- **[风险] 组级进度轮询频率增加** → `TaskGroupRecord` 的 `total_size` 是静态值，只有各 item 的 `transferred` 需要轮询，与现有轮询频率一致，不增加开销。
- **[权衡] Path A 和 Path B 并存** → 本次不合并两条路径，因为连接策略差异大（Path A 逐文件建连 vs Path B 单连接复用），合并属于独立变更。聚合模块只影响分组规则，不影响执行路径。
- **[风险] UUID 生成位置** → 组 ID 的 UUID 在 Rust 侧生成（`uuid` crate 已在依赖中），确保 FFI 两侧 ID 一致。
