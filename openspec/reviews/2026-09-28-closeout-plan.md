# 当前版本闭环推进计划

> 编制日期：2026-09-28｜基线：`d8f2c65`｜上游：[当前版本代码评审](2026-09-28-current-release-review.md)
> 目标：完成评审报告 §六列出的全部缺口，归档当前版本所有活跃提案，解除进入下一版本的阻塞
> 约束：TDD 红绿循环、覆盖率门禁（lines ≥ 95%、regions ≥ 95%）、OpenSpec 严格校验通过

## 一、总体策略

评审报告识别出 **6 类缺口**，按依赖关系和工作量分为四批次推进。批次之间有严格的前置依赖，不能并行：

```
批次A（P0 快速闭环）── 批次B（三提案协同收口）── 批次C（SftpSessionStore 独立）── 批次D（XCTest 复测 + 归档）
   ↑                    ↑                              ↑
   │                    │                              └─ 从 migrate Phase 4 任务 299-300 拆出
   │                    └─ improve-sftp-task-interactions 2.1-2.4 定义契约为全链起点
   └─ 无外部依赖，可立即执行
```

| 批次 | 性质 | 工作量估计 | 前置 | 退出条件 |
|---|---|---|---|---|
| A | P0 快速闭环（规格修复）| 小（<2 天）| 无 | `openspec validate --specs --strict` 31/31；3 项 next-release validate 通过 |
| B | 三提案协同收口 | 大（7-10 天）| A | Swift 4 处业务逻辑残留清零；三提案归档；主规格无新增 invalid |
| C | SftpSessionStore 视图选择重构 | 中（3-5 天）| B（migrate Phase 4 其余任务完成后）| SftpTabView 原生选择替换完成；编译通过；相关 XCTest 全绿 |
| D | XCTest 复测 + 完整产物重建 + 当前版本归档 | 中（2-3 天）| B + C | XCTest 全绿；build-rust.sh→xcodegen→双端 xcodebuild 通过；所有当前版本提案归档 |

## 二、批次A：P0 快速闭环（规格修复）

三个独立的规格工件修复，可并行执行。**优先级最高**，因为它们阻塞批次B的规格合并和next-release启动。

### A1. 修复主规格 2 项 invalid

| 文件 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `openspec/specs/sftp-batch-transfer/spec.md#L385` | 残留 `## ADDED Requirements` delta header（[unify-upload-file-task-queue](changes/archive/2026-09-23-unify-upload-file-task-queue/) 归档时未清理）| 删除 `## ADDED Requirements` header，把 `上传扫描失败不得隐式继续` 和 `同一上传目标避免并行写入` 两个 Requirement 直接归入主 `## Requirements` section | 修复 strict 校验 invalid；归档工件需同步更新；不改变任何行为 |
| `openspec/specs/transfers/spec.md#L336` | 同上，残留 `## ADDED Requirements` | 同上（`目录准备与零文件组可观察`、`传输准备操作的可见交接` 归入主 section）| 同上 |

修复后验证：`openspec validate --specs --strict` 31/31 通过。

### A2. 修复 3 项 next-release 提案 delta 工件结构

| 提案 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `add-ssh-proxy-jump` | spec delta 写在单文件 `spec-deltas.md`，OpenSpec 无法解析（"No deltas found"）| 按 delta 涉及的能力拆分为 `specs/host-config/spec.md`、`specs/ssh-connection/spec.md`、`specs/host-key-verification/spec.md` | 开始实施前必须完成，否则无法归档合并 |
| `deepen-snippet-system` | 同上 | 按涉及能力拆分（`specs/snippets/spec.md` 等）| 同上 |
| `improve-connection-reliability` | 同上 | 按涉及能力拆分（`specs/shell-terminal/spec.md`、`specs/workspace/spec.md` 等）| 同上 |

修复后验证：`openspec validate <change> --strict` 三项均返回 valid。

## 三、批次B：三提案协同收口

三个提案共享同一批状态与 FFI 契约，必须按依赖顺序推进，不能并行。**核心原则**：先统一任务类型/聚合/生命周期契约 → 再补 Swift 侧收口 → 最后归档。

### 依赖链

```
improve-sftp-task-interactions 2.1-2.4（定义类型化任务契约）
    ↓
improve-sftp-task-interactions 3.x-7.x（删除核心 + FFI + 任务页 + 停机）
    ↓
rust-sftp-task-aggregation Swift 收口（TransferStore.taskGroups → core::task_aggregation）
    ↓
migrate-business-logic-to-rust Phase 4 收尾（TerminalSessionStore + ConnectionGate + pendingTofu）
```

### B1. improve-sftp-task-interactions（2/26 → 全部完成）

此提案是整个链条的起点，因为它定义了类型化任务契约，后续 rust-sftp-task-aggregation 和 migrate 都依赖这个契约。

| 任务组 | 关键缺口 | 前置 |
|---|---|---|
| 2.1-2.4 刷新与摘要基础 | 类型化修订通知 + 未完成摘要（必须先做，定义契约）| 批次A |
| 3.1-3.4 删除核心 | core 显式栈扫描 + 独立删除任务生命周期 | 2.1-2.4 |
| 4.1-4.4 类型化 FFI 与任务页面 | 四类任务转换 + 同步接口 + Swift 任务页接入 | 3.x |
| 5.1-5.2 删除进度交互 | 进度弹窗 + 后台任务页 | 4.x |
| 6.1-6.2 右键选择修复 | 菜单展示前原生事件更新选择 | 4.x |
| 7.1-7.2 统一停机参与 | SFTP 任务登记门禁 + 协作取消 | 4.x |

关键契约决策（需在实施前明确）：
- 任务类型统一为 Upload/Download/Delete/Prepare 四类
- `delete_tasks` 的 FFI 是否需要独立入口，还是复用 `sftp_*` 系列加方向参数
- 传输任务组级聚合规则是否完全复用 `unify-upload-file-task-queue` 的逐文件模型

### B2. rust-sftp-task-aggregation（Swift 收口）

此提案的任务组级聚合已在 `panda-core::task_aggregation` 实现，但 Swift 侧 `TransferStore.taskGroups/cancelGroup/retryGroup/pauseGroup/resumeGroup` 仍自行实现规则，未通过 FFI 接入。

| 文件 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `apple/PandaSSH/Workspace/TransferStore.swift` | `taskGroups` 字典自维护，`cancelGroup/retryGroup/pauseGroup/resumeGroup` 自行实现组级操作 | 删除 Swift 侧 `taskGroups`，改为从 core FFI 拉取；组级操作全部委托给 core | 解锁 rust-sftp-task-aggregation 归档；影响传输任务页所有组级交互 |
| `crates/panda-ffi/src/task_aggregation.rs` | 当前只有聚合函数，无组级操作入口 | 新增同步 FFI 入口：`cancel_group`、`retry_group`、`pause_group`、`resume_group` | TransferStore 可直接调用 core，消除 Swift 侧业务逻辑 |
| `migrate-business-logic-to-rust/tasks.md` Phase 2.2 | 聚合路径验证任务（标注 `- [ ]`）| 依赖 B1 的类型化任务契约完成后执行 | 补齐 migrate 提案的验证门禁 |

### B3. migrate-business-logic-to-rust Phase 4 收尾

依赖 B1（Task 3.x-7.x 的删除核心和停机协作）和 B2（TransferStore 收口）。

| 文件 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `apple/PandaSSH/Workspace/TerminalSessionStore.swift` | 状态机仍在 Swift | 删除状态机逻辑，保留 `@Published` 转发壳；连接/重连/关闭全部委托 core | 解锁 migrate 归档；影响终端连接/重连/关闭路径 |
| `apple/PandaSSH/Workspace/ConnectionGate.swift#L48-L141` | TOFU 探测、`tofuRegister`/`tofuAwaitOutcome`/`HostKeyMismatchError` 分支仍 Swift | 与 `panda-core/src/tofu.rs` 的 TofuCoordinator 合并收口 | 影响 host key 流程与未知主机弹框时序；重跑 TOFU 相关 XCTest |
| `AppModel.pendingTofu` | TOFU 等待状态仍 Swift | 删除，改为订阅 core 遥测事件 | 与 ConnectionGate 收口同步进行 |
| `migrate-business-logic-to-rust/tasks.md` Phase 4 任务 | 剩余 8 项未勾（201/213）| 完成 TerminalSessionStore 退化、ConnectionGate 收口、pendingTofu 删除、config-archive 能力口径明确 | 归档前必须修复受影响测试 |
| config-archive 能力口径 | migrate Phase 5 引入 `config-archive`，与既有 `config-export-import`、`config-sync` 域接近 | 合并入 `config-export-import` 能力，不新建独立目录 | 避免主规格同域多能力目录 |

### B4. migrate-business-logic-to-rust Phase 4.5：SftpSessionStore 业务路由下沉

原 migrate 提案 Phase 4 任务 299-300 仅跟踪选择逻辑（已拆到批次C），但 SftpSessionStore 还包含**业务路由/编排方法**——它们含业务决策分支（如"双击文件→上传/双击目录→进入"），按 AGENTS.md"业务逻辑只在 panda-core"应下沉 Rust。这批方法之前被遗漏，作为 Phase 4.5 补齐：

| 文件 | 方法 | 业务决策 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|---|
| `SftpSessionStore.swift#L1110` | `doubleClickLocal` | 目录→进入，文件→上传 | 下沉为 Rust 路由决策函数，Swift 侧退化为调用 | 双击行为在 Rust 统一 |
| `SftpSessionStore.swift#L1119` | `contextUpload` | 未选中→选中再上传，已选中→直接上传 | 同上 | 右键菜单上传行为 |
| `SftpSessionStore.swift#L1130` | `doubleClickRemote`/`contextDownload` | 同上（下载方向） | 同上 | 同上 |
| `SftpSessionStore.swift#L1237` | `uploadSelected` | 多选→批量上传，目录→目录上传，单文件→覆盖确认 | 下沉为 Rust 路由决策 + `orchestrateSftpTransfers` 调用 | 上传入口统一 |
| `SftpSessionStore.swift#L1255` | `downloadSelected` | 同上（下载方向） | 同上 | 同上 |
| `SftpSessionStore.swift#L1502` | `deleteLocalBatch`/`deleteRemoteBatch` | 批量删除路由（已部分委托 FFI） | 下沉为 Rust 删除任务入口（需 improve-sftp-task-interactions 删除核心完成后才有完整契约）| 删除入口统一 |
| `SftpSessionStore.swift#L914` | `resolveBatchConflict`/`resolveConflict` | 冲突决策回传 | 下沉为 Rust 决策协议 | 冲突处理统一 |
| `SftpSessionStore.swift#L1273` | `upload(localPaths:)` 路径拼接、`BatchItemRecord` 转换 | 参数组装仍是 Swift 业务逻辑 | 随路由下沉一并迁入 Rust | 减少 Swift→Rust 边界泄漏 |

**前置**：B1（improve-sftp-task-interactions 2.1-7.2）完成后，删除核心和类型化任务契约齐备，B4 才能有完整的 Rust 入口可调用。批次C的选择状态迁移**不阻塞**B4——业务路由方法从 `@Published selectedLocalSet` 改为读 `@State localSelection` 只是数据源切换，路由分支本身不依赖选择状态是 `@Published` 还是 `@State`。

### 批次B 退出条件

- Swift 侧**全部业务逻辑**残留清零（TerminalSessionStore、ConnectionGate + pendingTofu、TransferStore.taskGroups、SftpSessionStore 业务路由方法）
- SftpSessionStore 选择状态（`selectedLocalSet`/`selectedRemoteSet`/`anchor`）**除外**——这部分是批次C的独立提案跟踪
- 三提案（improve-sftp-task-interactions、rust-sftp-task-aggregation、migrate-business-logic-to-rust）全部归档
- `openspec validate --specs --strict` 保持 31/31 通过（批次A的修复需同步合并 delta）
- Rust 覆盖率门禁保持通过；相关 XCTest 全绿

## 四、批次C：SftpSessionStore 视图选择重构（独立提案）

从 `migrate-business-logic-to-rust` Phase 4 任务 299-300 拆出，单独创建 OpenSpec 变更提案。**定位**：SwiftUI 视图层选择机制重构，非 Rust 业务逻辑下沉。

### 拆分依据

原 migrate Phase 4 任务：
- 299：`SftpSessionStore` 选择逻辑——已评估标注"待视图层重构为原生选择后再删除"
- 300：SFTP 视图改用 `List(selection:)` 原生选择

这两项本质是 SwiftUI 视图交互层重构（`List(selection:)` + 拖拽框选/Shift/Command 修饰键迁移），不属于"业务逻辑下沉 Rust"范畴，不应继续挂在 migrate 提案下。

### 新提案定位

| 属性 | 值 |
|---|---|
| 提案名 | `refactor-sftp-view-selection` |
| 类型 | 重构（UI 交互层）|
| 归属 | 当前版本（作为 migrate Phase 4 的独立收尾）|
| 与原 migrate 提案关系 | 拆分移出；migrate Phase 4 任务 299-300 从原 tasks.md 删除 |
| 前置 | 批次B完成后（Swift 侧不再新增业务逻辑残留约束）|

### 关键缺口

| 文件 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `apple/PandaSSH/Workspace/SftpSessionStore.swift#L643-L679` | `selectedLocalSet`/`selectedRemoteSet`/`localAnchor`/`selectLocal`/`selectRange`/`toggleMultiSelect` 等属性和方法与 900+ 行视图深度耦合 | 迁移到 SwiftUI `List(selection: Set<String>)` 原生绑定；删除旧属性和方法 | SftpSessionStore 瘦身为纯导航状态管理；消除最后一处"待迁移"注释 |
| SftpTabView 拖拽框选 | 当前自定义实现，与旧选择方法紧耦合 | 迁移为 SwiftUI `.gesture()` 修饰符 + 拖拽选区覆盖层 | 减少 900+ 行复杂交互代码 |
| 右键菜单高亮与选择状态 | 菜单操作与当前选择集不同步 | 菜单展示前用原生事件更新共享选择状态（已有参考：`improve-sftp-task-interactions` 任务 6.x）| 修复"右键菜单操作与高亮不一致"的既有缺陷 |

### 批次C 退出条件

- SftpSessionStore 不再包含 `selectedLocalSet`/`selectedRemoteSet`/`localAnchor` 等选择相关属性
- SftpTabView 改用 `List(selection: Set<String>)` 原生选择
- 拖拽框选、Shift/Command 修饰键、右键菜单全部正常工作
- 编译通过；FilePaneNavigator 相关 XCTest 全绿
- migrate-business-logic-to-rust tasks.md 删除任务 299-300，更新完成度（211/213 → 213/213）

## 五、批次D：XCTest 复测 + 完整产物重建 + 当前版本归档

依赖批次B和C全部完成。

### D1. macOS XCTest 复测

9-11 报告记录 35 项失败（7 个测试类），本轮环境问题导致未复测。批次B/C 修改了 Swift 大量代码，必须验证：

| 测试类 | 9-11 失败数 | 可能随 B/C 修复的原因 |
|---|---|---|
| AppModelSelectionTests | 8 | 统一传输队列 + 选择逻辑下沉 |
| GlobalTransferNavigationTests | 1 | 同上 |
| FilePaneNavigatorTests | 2 | SftpSessionStore 选择重构（批次C）|
| LoggerBufferTests | 4 | Logger 已委托 Rust FFI |
| LoggerFileTests | 7 | 同上 |
| TransferStoreTests | 9 | TransferStore 收口到 core（批次B）|
| WorkspaceStoreTests | 4 | 页签标题稳定化已归档 |

### D2. iPadOS arm64 模拟器 XCTest + Swift 全应用覆盖率

9-11 报告通过 build-for-testing，但未运行测试。批次B/C 大量修改双端共享 Swift 源码，必须在 iPadOS 目标验证：

- `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS -destination "platform=iOS Simulator,arch=arm64" test`
- Swift 全应用覆盖率测量（无门禁要求，但需有基线数据）

### D3. 完整产物重建链

- `bash apple/Scripts/build-rust.sh`
- `cd apple && xcodegen`
- macOS + iPadOS 双端 `xcodebuild`

### D4. 单文件覆盖率缺口

评审报告 §六列出三个文件覆盖率低于 95%（整体门禁已过，单文件无门禁但需跟踪）：

| 文件 | 当前 regions / lines | 处置策略 | 前置 |
|---|---|---|---|
| `panda-core/src/ssh.rs` | 90.17% / 91.56% | 批次B TerminalSessionStore 下沉 + improve-sftp-task-interactions 完成后，补正常/失败/边界用例覆盖未测分支 | 批次B |
| `panda-core/src/sftp.rs` | 94.28% / 93.80% | 同上，随 improve-sftp-task-interactions 的删除核心测试补齐 | 批次B |
| `panda-ffi/src/ffi_store.rs` | 90.42% | 批次B TransferStore 收口后，补 store 错误路径测试 | 批次B |

完成判据：三文件 regions 和 lines 均 ≥ 95%。不阻塞归档，但归档前必须补齐——因为这些文件的未覆盖分支在批次B/C 修改后可能成为回归点。

### D5. 当前版本提案归档

活跃提案（评审报告 §五 25 项 + 新增 `refactor-sftp-view-selection` = 26 项）逐项映射到批次：

| 批次 | 提案 | 归档条件 |
|---|---|---|
| A（规格修复）| 无新提案归档（仅修主规格 invalid）| delta header 清理后随批次B的 delta 合并一起归档 |
| B（三提案收口）| improve-sftp-task-interactions | 任务 2.1-7.2 全部完成；Swift 侧删除核心 + 停机协作接入 |
| B | rust-sftp-task-aggregation | TransferStore.taskGroups 收口；组级操作委托 core |
| B | migrate-business-logic-to-rust | Phase 4 + Phase 4.5 完成；TerminalSessionStore/ConnectionGate/pendingTofu 收口；SftpSessionStore 业务路由下沉 |
| B（已完成提案，待归档）| add-tab-switch-shortcut | strict 校验通过；100% 勾选 |
| B | fix-config-import-zip-slip | 同上 |
| B | fix-tab-strip-intrinsic-width | 同上 |
| B | harden-credential-file-permissions | 同上 |
| B | remove-unreferenced-code | 同上 |
| B（主体完成提案，待验收后归档）| terminal-mouse-interaction 18/31 | 补 iPadOS 测试 + Swift 覆盖率 + 触摸/外接鼠标验收 |
| B | use-alert-for-connection-close 8/10 | 补双端系统警告框人工验收 |
| B | fix-macos-tab-drag-and-titlebar-zoom 14/15 | 补真实窗口几何验收 |
| B | add-tab-close-and-quit-shortcuts 16/21 | 补剩余 5 项任务 |
| B（部分完成提案，随批次B收口后归档）| fix-settings-experience 28/36 | 批次B完成后补剩余 8 项 |
| B | fix-ssh-session-failure-diagnostics 2/30 | 批次B完成后推进 |
| B | preserve-disconnected-session-tabs 1/15 | 批次B完成后推进 |
| B（被替代提案，关闭归档）| refactor-macos-titlebar-tab-strip 0/13 | 记录被统一 chrome 替代，不实施直接关闭 |
| C（新增独立提案）| refactor-sftp-view-selection | 批次C 完成 |
| 不归档（next-release）| improve-connection-reliability 0/80 | next-release.md 已排期 |
| 不归档（next-release）| add-ssh-proxy-jump 0/73 | next-release.md 已排期 |
| 不归档（next-release）| deepen-snippet-system 5/84 | next-release.md 已排期 |
| 不归档（next-release）| add-batch-remote-execution 0/47 | next-release.md 已排期 |
| 不归档（next-release）| add-manual-inspection-loop 0/50 | next-release.md 已排期 |
| 不归档（next-release）| tab-page-memory-indicator 0/8 | next-release.md 已排期 |
| 不归档（next-release）| terminal-buffer-size 0/9 | next-release.md 已排期 |
| 不归档（next-release）| add-command-audit-trail 0/22 | next-release.md 已排期 |
| 不归档（next-release）| add-execution-plan-authorization 0/18 | next-release.md 已排期 |
| 不归档（next-release，当前版本纳入）| add-app-internationalization 12/66 | 评审报告标记为"部分完成"，next-release 继续 |

- 归档口径：`openspec validate <change> --strict` 通过 → delta 语义合并回 `openspec/specs/`（保留已归档变更的新场景，禁止旧 Requirement 整段覆盖）→ `openspec archive` → 主规格 strict 校验 31/31

## 六、风险与降级

| 风险 | 可能性 | 影响 | 降级策略 |
|---|---|---|---|
| improve-sftp-task-interactions 2.1-2.4 契约无法达成一致 | 中 | 阻塞批次B全部 | 先用 Fake/Spec 桩推进后续任务，后续补真实契约 |
| TerminalSessionStore 下沉后终端回归严重 | 中 | 阻塞 migrate 归档 | 保留旧实现作 fallback，逐步迁移每个方法 |
| SftpSessionStore 视图选择重构引入大量回归 | 高 | 阻塞批次C | 分阶段迁移：先改本地栏 → 远程栏 → 拖拽框选，每步通过验证 |
| XCTest 仍有大量失败 | 中 | 阻塞批次D | 逐项修复，不删除断言；参考 9-11 报告的 7 类失败根因 |
| iPadOS 静态链接问题（rusqlite bundled）| 低 | 影响下一版本 | 批次D 仅做基线测量，下一版本实施前处理 |
