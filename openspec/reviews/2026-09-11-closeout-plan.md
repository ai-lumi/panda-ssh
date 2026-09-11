# 当前版本收尾任务规划

> 编制日期：2026-09-11｜基线：`b138c38`（与《2026-09-11 当前版本提案归档复核》相同，代码未变，复核报告的测试结论继续有效）。
> 本轮独立复核重新确认：任务勾选计数 18/18 项与报告一致；`cargo test --workspace` 全绿；主规格严格校验 25/26；报告关键论断（snippets 伪 Requirement、config.yaml 钥匙串表述、batch_transfer.rs 超时即跳过、Swift 组级操作自实现、`Delete => Upload` 映射、缺 design 工件等）全部属实。
> 结论：**当前版本 18 项中 0 项满足归档条件**。归档动作统一推迟到对应批次的前置任务完成后执行。

## 一、本轮复核新增发现（复核报告未覆盖）

1. **下一版本 3 项提案 strict 校验失败**：`add-ssh-proxy-jump`、`deepen-snippet-system`、`improve-connection-reliability` 的 spec delta 写在单文件 `spec-deltas.md`，不符合 `specs/<capability>/spec.md` 目录结构，OpenSpec 无法解析 delta（"No deltas found"）。其余 6 项下一版本提案校验通过。开始实施前必须重构这三份工件，否则将来无法归档合并。复核报告只验证了 18 个当前版本提案，未覆盖下一版本。
2. **能力命名口径风险**：`migrate-business-logic-to-rust` 的 delta 引入新能力 `config-archive`，与既有主规格 `config-export-import`、`config-sync` 域接近，合并时需确认是新建能力还是并入既有能力，避免同一域出现多个能力目录。
3. **"✓ Complete" 不是归档依据**：`openspec list` 将 4 项标为 Complete（任务全勾口径）：`align-apple-build-targets-and-config-warnings`、`fix-sftp-directory-upload-path-duplication`、`fix-sftp-batch-upload-blocking`、`native-swiftui-chrome`；四项均未满足归档前提（见下）。
4. **未提交的版本边界文档**：`next-release.md`、本规划与复核报告、`tab-page-memory-indicator` 与 `terminal-buffer-size` 两份 proposal.md（各 +3 行）尚未提交；建议先提交固化"当前版本 / 下一版本"边界。是否创建版本分支由用户决策后执行。

## 二、公共前置任务（阻塞一切归档）

| # | 任务 | 完成标准 |
| --- | --- | --- |
| P0 | 提交当前 openspec 文档变更，确定是否建版本分支 | 工作区干净 |
| P1 | 修正规格基线：`snippets/spec.md` 第 44 行"当前实现状态"降级为说明性章节；`config.yaml` 第 8 行改为 credentials.toml 凭据文件基线 | `openspec validate --specs --strict` 26/26 |
| P2 | 为 35 个 Swift 失败用例（7 个测试类）先确定正确契约再修复，不删除断言 | macOS XCTest 全量通过 |
| P3 | 补 Rust 覆盖率至 95%/95%（`panda-ffi/src/lib.rs` 82.91%/82.27% 为主要缺口），结合未验证 FFI 行为补正常/失败/边界测试 | `cargo llvm-cov` 门禁退出码 0 |
| P4 | 平台与环境补齐：Linux 交叉编译器、iPadOS XCTest、Swift 覆盖率测量、完整 `build-rust.sh → xcodegen → 双端构建` 产物重建 | 各项有有效通过证据 |

## 三、部分实施 4 项（同一批状态与 FFI 契约，按依赖排序）

| 顺序 | 提案 | 关键缺口 |
| --- | --- | --- |
| 1 | improve-sftp-task-interactions（2/28） | 先统一任务类型/聚合/生命周期契约；修复 `task_aggregation.rs:66` 的 `Delete => Upload` 映射；完成任务 2–7 与验收 |
| 2 | rust-sftp-task-aggregation（31/33） | Swift `taskGroups`/`cancelGroup`/`retryGroup`（TransferStore.swift:625/791/797）收口到 core → FFI；统一 tasks 与 proposal/design 的收口口径 |
| 3 | migrate-business-logic-to-rust（199/207） | `TerminalSessionStore`、`ConnectionGate`、`pendingTofu` 及选择逻辑收口；处理 `config-archive` 能力口径；合并 10 个能力 delta |
| 4 | define-ssh-content-page-lifecycle（2/8） | 真实装配、尺寸变化、可见性、会话连续性测试；明确 resize 最终契约 |

## 四、主体实现 11 项收尾（逐项：delta 语义合并 + 补验收 + 任务状态写实）

| 提案 | 剩余条件 |
| --- | --- |
| align-apple-build-targets-and-config-warnings（10/10） | 完整产物重建与告警复核证据；更新验证依据 |
| fix-sftp-directory-upload-path-duplication（8/8） | 主规格补中文目录上传场景，语义合并 delta |
| add-unsigned-macos-release（5/6） | 覆盖率门禁记录；Universal Release 工件证据；创建 `unsigned-macos-release` 主规格 |
| fix-sftp-batch-upload-blocking（18/18） | 确定超时产品语义（实现为超时跳过），补可控时钟超时测试；design 反映 `block_in_place` 线程模型；同步两个 delta |
| fix-tab-strip-rightmost-truncation（0/13） | 补 design；任务状态写实（实现已存在）；统一主规格与 delta；真实窗口几何验收 |
| fix-terminal-exit-status（7/8） | delta 按当前"所有者独占连接"语义重合并，不恢复共享连接 |
| fix-window-top-flicker-on-transfer（13/18） | 真实传输期间顶部稳定、空闲 CPU、侧栏/窗口变化、多会话连续性验收；同步两个 delta |
| fix-workspace-tab-close-identity（3/5） | 修复 WorkspaceStore 其余四项标题测试（属 P2）；真实警告框/会话验收 |
| refactor-sftp-global-transfers（13/16） | 选择/分组回归修复（属 P2）；Swift 覆盖率；宽窄布局、窗口重复激活、关页续传验收 |
| terminal-mouse-interaction（18/31） | 任务证据更新；iPadOS 测试、Swift 覆盖率；触摸/外接鼠标/Universal Control 验收；同步 workspace delta |
| use-alert-for-connection-close（4/10） | 双端系统警告框人工验收；覆盖率记录；同步更严格的 alert 与批量确认规格 |

## 五、历史 UI 3 项关闭（按替代关系，不合并旧 delta）

| 提案 | 关闭动作 |
| --- | --- |
| native-swiftui-chrome（28x + 2[~]） | 记录采纳/替代范围与两个 `[~]` 的处置 → 归档关闭 |
| refactor-macos-titlebar-tab-strip（0/13） | 记录被统一 chrome 替代的原因与承接关系 → 归档关闭 |
| swiftui-workspace-visual-refresh（26/29） | 先拆分采纳项与被替代项；未完成的无障碍/视觉验收转入验收任务后关闭；禁止整份旧 delta 覆盖主规格 |

## 六、归档批次（前置任务完成后执行）

| 批次 | 内容 | 前置 |
| --- | --- | --- |
| A | fix-sftp-directory-upload-path-duplication、align-apple-build-targets-and-config-warnings、add-unsigned-macos-release、fix-sftp-batch-upload-blocking | P1–P4 + 各项剩余条件 |
| B | 历史 UI 3 项关闭 | 替代范围记录 |
| C | 其余 11 项按实现完成顺序逐项归档 | P1–P4 + 对应章节三/四任务 |

归档统一口径：`openspec validate <change> --strict` 通过 → delta 语义合并回 `openspec/specs/`（保留已归档变更的新场景，禁止旧 Requirement 整段覆盖）→ `openspec archive` → 主规格严格校验 26/26。

## 七、下一版本启动条件

- 活动变更仅剩下一版本清单中的 9 项，当前版本无隐藏未完成任务。
- 先重构 3 项 delta 工件结构（`add-ssh-proxy-jump`、`deepen-snippet-system`、`improve-connection-reliability`），再开始实施。
- 实施中同步更新 `next-release.md` 的实施状态列。
