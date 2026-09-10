# 设计：业务逻辑下沉 Rust

## Context

参见 proposal.md。当前 Swift 前端存在 41 处业务逻辑泄漏，分布在 14 个文件中。同时现有单元测试存在大量缺口——8 个核心 Spec 领域零测试覆盖。本设计文档定义迁移的技术方案和分阶段策略。

## Goals / Non-Goals

### Goals

- 所有业务逻辑由 Rust `panda-core` 拥有，Swift 前端仅做 UI 渲染和用户操作转发
- 迁移前后行为完全一致（通过测试保障）
- 迁移后的 Rust API 可被任意前端（macOS/iPadOS/Linux）直接调用
- 消除 Rust/Swift 重复实现（`GroupTree` vs `groups.rs`）

### Non-Goals

- 不实现 Linux 前端（仅做准备）
- 不改变现有业务规则
- 不引入新的 UI 框架依赖

## Decisions

### 1. 测试先行，迁移在后

**决定**：Phase 0 先补齐所有 Swift 侧单元测试，覆盖率达标后再开始迁移。

**理由**：
- 当前 8 个核心 Spec 领域（host-key-verification、credential-protection、host-config、connection-pool、shell-terminal、sftp-transfer、settings-tab-bar、config-sync）零测试覆盖
- 没有测试保护的重构无法验证行为一致性
- 迁移到 Rust 后测试将用 Rust 重写，Swift 测试是迁移的"行为规格文档"

**拒绝方案**：边迁移边补测试——风险过高，无法区分"迁移引入的 bug"和"原本就存在的 bug"。

### 2. 逐模块迁移，每个模块独立可验证

**决定**：按 Phase 1→4 顺序逐模块迁移，每个模块完成后独立可编译、可测试、可回滚。

**理由**：
- 大爆炸式迁移风险不可控
- 逐模块迁移允许在任意阶段暂停或回滚
- 每个模块迁移后 `cargo test` + `xcodebuild` 全绿即可提交

### 3. 推送通道替代轮询（增量引入）

**决定**：Phase 3 引入 `TransferObserver` 回调 trait，但不立即移除现有轮询 API。前端可选择使用推送或继续轮询。

**理由**：
- 现有 `transfer_list()` 轮询 API 仍然有效，Linux 前端可用轮询起步
- 推送通道是性能优化，不是功能变更
- 增量引入降低迁移风险

**拒绝方案**：直接移除轮询 API——破坏性变更，影响面过大。

### 4. 选择逻辑不迁移，改用 UI 框架原生能力

**决定**：`SftpSessionStore` 中的选择逻辑（单选/多选/范围选/锚点追踪）不下沉到 Rust，而是删除，改用 SwiftUI `List(selection:)` / GTK `Gtk.SelectionModel` 的原生选择能力。

**理由**：
- 文件选择是标准 UI 交互，所有成熟 UI 框架都原生支持
- 后端不应知道"用户选了哪些文件"，只应接收"用户要传输这些路径"
- 保留选择逻辑在 Swift 侧是架构错误

### 5. 面包屑计算留在前端

**决定**：`FilePaneNavigator.breadcrumbs` 的路径分解逻辑不迁移到 Rust，前端 `path.split("/")` 即可。

**理由**：
- 纯字符串操作，无业务规则
- 不同前端可能有不同的面包屑展示策略（截断、图标等）
- 后端只需提供 `current_path: String`

### 6. 侧栏树由后端组装

**决定**：`SidebarTree.build()` 的层级组装逻辑迁移到 Rust，后端返回已组装好的 `Vec<SidebarNodeRecord>`。

**理由**：
- 树形结构是业务数据的固有属性（分组包含主机、分组包含子分组）
- 孤儿节点降级、排序规则是业务规则而非 UI 规则
- 所有前端都需要相同的树形结构

## Risks / Trade-offs

### 风险 1：FFI 调用频率增加

**描述**：业务逻辑下沉后，前端可能需要更频繁地调用 FFI 获取状态更新。

**缓解**：Phase 3 引入推送通道，前端被动接收变更。在推送通道就绪前，前端可用合理的轮询间隔（1-2Hz）。

### 风险 2：Rust 侧代码量膨胀

**描述**：新增模块增加 `panda-core` 维护成本。

**缓解**：新增模块都是迁移现有 Swift 逻辑，不是新功能。且消除了 Rust/Swift 重复实现，净代码量减少。

### 风险 3：迁移期间功能回归

**描述**：大规模重构可能引入行为差异。

**缓解**：
- Phase 0 确保测试覆盖 ≥ 95%，作为行为规格
- 逐模块迁移，每个模块完成后全量测试通过
- Rust 实现必须有对等测试，覆盖 Swift 测试的所有场景

### 风险 4：Swift 测试迁移到 Rust 的语义差异

**描述**：Swift 测试中使用的 Mock/注入模式在 Rust 中可能需要不同的实现方式。

**缓解**：Rust 使用 trait 抽象 + mockall crate 实现等效的依赖注入。每个 Swift 测试场景必须有一个对应的 Rust 测试。

## Migration Plan

### Phase 0：测试补齐（预估 10-15 天）

对照 26 个 OpenSpec Specs，补齐 Swift 侧缺失的单元测试。重点覆盖：

1. **host-key-verification**：known_hosts CRUD、三态判断、TOFU 存取、密钥删除（当前零测试）
2. **credential-protection**：保护密钥设置/变更/移除、加密读取、篡改检测（当前零测试）
3. **host-config**：TOML 序列化往返、端口默认值、原子写入、损坏文件处理（当前零测试）
4. **connection-pool**：owner 隔离、空闲保活、精确关闭幂等性（当前零测试）
5. **shell-terminal**：PTY 分配、命令执行超时、输出收集（当前零测试）
6. **sftp-transfer**：目标存在检测、覆盖确认元数据、跳过/覆盖决策（当前零测试）
7. **现有模块缺口**：GroupTree `move_group` 循环拒绝、TransferStore 自适应轮询、ConfigExportImport iOS 覆盖、Logger 并发安全

门禁：`cargo test` 全绿 + Swift 测试覆盖率 lines ≥ 95% 且 regions ≥ 95%。

### Phase 1：纯算法下沉（预估 5-7 天）

迁移无状态、无平台依赖的纯计算逻辑到 Rust。每个模块：先写 Rust 测试 → 实现 → 删除 Swift 代码 → 验证。

1. `TransferSpeedTracker` 内置到 `TransferTask`，FFI 返回 `speed`/`eta_seconds`
2. `transfer_groups()` 聚合 API
3. `search_hosts(query)` 搜索 API
4. `group_path(group_id)` 路径 API
5. `sidebar_tree()` 树组装 API
6. `credential_resolve(host_id)` 凭据解析 API
7. `connection_failure_classify(error_code)` 错误分类 API

### Phase 2：基础设施下沉（预估 5-7 天）

1. `config_export()` / `config_import()` — 用 Rust `zip` crate 替代手写 ZIP
2. `log_entries()` / `log_write()` / `log_clear()` — 环形缓冲 + 文件轮转

### Phase 3：状态管理下沉（预估 10-15 天）

1. `workspace_*` 标签页管理 API（标题去重、状态聚合、关闭确认）
2. `terminal_session_*` 会话状态机（代际追踪、过期清理）
3. `preconnect_evaluate()` + TOFU 并发序列化
4. `TransferObserver` 推送通道替代轮询

### Phase 4：Swift 瘦身（预估 5-7 天）

1. 所有 ViewModel 退化为 `@Published` 转发
2. 删除 `SftpSessionStore` 选择逻辑，改用 `List(selection:)`
3. 传输编排改为调用 Rust 单一 API
4. 删除所有已迁移的 Swift 文件和代码

### 回滚策略

每个 Phase 独立可回滚。回滚方式：恢复已删除的 Swift 代码（通过 git），移除对应的 Rust 新增 API。Phase 间无硬依赖。
