# 提案：业务逻辑下沉 Rust，前端仅保留视图层

## Why

当前 Swift 前端承担了过多业务职责，违反前后端分离原则：

- **数据查询**：`GroupTree` 用 Swift 重写了一遍 Rust 已有的树遍历算法；`SidebarTree.build()` 在前端拼装层级结构；`HostSearch` 在前端遍历全量数据做搜索
- **状态管理**：`WorkspaceStore` 管理标签页生命周期和标题去重；`TerminalSessionStore` 维护连接状态机；`SftpSessionStore` 管理文件面板导航和传输编排；`TransferStore` 做任务分组聚合和自适应轮询
- **业务计算**：`TransferSpeedCalculator` 在前端算速度和 ETA；`CredentialResolver` 在前端决定凭据优先级；`ConnectionGate` 在前端做连接前评估和 TOFU 并发序列化
- **基础设施**：配置导入导出、ZIP 格式实现、日志环形缓冲和文件轮转全部在 Swift 侧

后果：

1. 无法为 Linux 平台复用任何业务逻辑，每个前端都要重写一遍
2. Rust 和 Swift 存在重复实现（`GroupTree` vs `groups.rs`），行为可能不一致
3. 前端轮询 + 派生计算的模式效率低（`TransferStore` 5Hz 轮询后在前端算速度）
4. 现有单元测试覆盖不足——多个核心 Spec（host-key-verification、credential-protection、host-config、connection-pool、shell-terminal、sftp-transfer）在 Swift 侧零测试，迁移前必须补齐

## What Changes

1. **Phase 0（前置）**：对照 OpenSpec Specs 补齐 Swift 侧单元测试，确保所有业务逻辑在迁移前有完整测试覆盖（正常流程 + 意外操作 + 边界条件），覆盖率 ≥ 95%
2. **Phase 1**：纯算法下沉——速度计算、任务分组聚合、搜索、分组路径、侧栏树、凭据解析、错误分类迁移到 Rust
3. **Phase 2**：基础设施下沉——配置导入导出（用 Rust `zip` crate 替代手写 ZIP）、日志系统迁移到 Rust
4. **Phase 3**：状态管理下沉——标签页生命周期、终端会话状态机、连接前评估 + TOFU 序列化、传输推送通道替代轮询
5. **Phase 4**：Swift 瘦身——所有 ViewModel 退化为 `@Published` 转发层，删除选择逻辑改用 UI 框架原生能力

## Non-goals

- 不涉及 Linux 前端的实现（本提案仅完成 Rust 侧准备和 Swift 瘦身）
- 不改变现有 FFI 同步调用模式（Phase 3 引入推送通道是增量，不替换现有 API）
- 不新增业务功能
- 不改变 `panda-core` 的跨平台编译目标（Linux 可编译性不变）
- 不涉及 UI 视觉/交互变更

## Capabilities

### 新增

- `rust-workspace-manager`：Rust 侧标签页/工作区生命周期管理
- `rust-transfer-aggregation`：Rust 侧传输速度计算 + 任务分组聚合 + 推送通知
- `rust-config-archive`：Rust 侧配置导入导出（替代 Swift 手写 ZIP）
- `rust-logger`：Rust 侧日志管理（环形缓冲 + 文件轮转）
- `rust-preconnect`：Rust 侧连接前评估 + TOFU 并发序列化

### 修改

- `groups`：新增 `group_path()`、`sidebar_tree()` FFI 导出
- `hosts`：新增 `search_hosts()` FFI 导出
- `credentials`：新增 `credential_resolve()` FFI 导出
- `transfers`：`TransferStatusRecord` 新增 `speed`、`total_speed`、`eta_seconds` 字段
- `ffi-bridge`：新增推送回调注册 API

## Impact

### Rust 层

- `crates/panda-core`：新增 `workspace`、`transfer_speed`、`config_archive`、`logger` 模块；扩展 `groups`、`config`、`credentials` 模块
- `crates/panda-ffi`：新增约 30 个 `#[uniffi::export]` 函数；新增推送回调 trait

### Swift 层

- **删除文件**：`TransferSpeedCalculator.swift`、`CredentialResolver.swift`、`ConfigExporter.swift`、`ConfigImporter.swift`、`ConfigArchiveUtility.swift`、`SidebarTree.swift`
- **删除代码**：`Models.swift` 中 `GroupTree` + `HostSearch`；`WorkspaceStore.swift` 业务逻辑；`TerminalSessionStore.swift` 状态机；`SftpSessionStore.swift` 选择/导航/传输编排；`ConnectionGate.swift` 状态机；`Logger.swift` 数据层；`PandaCoreBackend.swift` 多步编排
- **保留**：所有 SwiftUI View 文件；ViewModel 退化为 `@Published` 转发；平台服务适配

### macOS / iPadOS

两端影响一致——Swift 前端均退化为薄视图层，行为不变。

### 测试

Phase 0 需新增约 200+ 测试用例覆盖当前缺口（详见 tasks.md）。后续每个 Phase 的 Rust 实现必须有对等 Rust 测试，Swift 侧删除对应测试。
