# Panda SSH 当前版本代码评审

> 评审日期：2026-09-28｜基线：`d8f2c65`（自 9-11 复核报告 `b138c38` 后推进 11+ 提交）｜目标：分析当前版本实现完整程度
> 实测：`cargo test --workspace`、`cargo llvm-cov`、`openspec validate --specs --strict`、`openspec validate <change> --strict`；macOS XCTest 因 SwiftBuildService 卡住未复测（环境问题，非评审阻塞）

## 一、整体结论

**实现完整度显著提升，但未达归档条件**。相比 9-11 复核报告，Rust 测试通过数翻倍（489→1074），覆盖率门禁从失败转为通过（lines 93.20%→97.07%），基线三处冲突全部消解，自 9-11 起新增归档 8 个变更。但仍有 4 处 Swift 业务逻辑残留、`improve-sftp-task-interactions` 仍是 2/26 最大缺口、OpenSpec 主规格出现 2 项新 invalid（delta header 残留）、3 项 next-release 提案 delta 工件结构问题未修复、macOS XCTest 35 项失败用例未复测。

## 二、量化指标对比

| 维度 | 当前实测 | 9-11 复核 | 增量 |
|---|---|---|---|
| Rust 测试通过 | 1074 | 489 | +585 |
| Rust 失败/忽略 | 0 / 4 | 0 / 4 | 持平 |
| 覆盖率 lines | 97.07% | 93.20% | +3.87pp（达标）|
| 覆盖率 regions | 96.74% | 92.70% | +4.04pp（达标）|
| 覆盖率门禁退出码 | 0（通过）| 1（失败）| 已闭环 |
| 基线冲突 | 0 处 | 3 处 | 全消解 |
| 活跃变更提案 | 25 | 18 | +7 |
| 9-11 后新增归档 | 8 | — | 见 §四 |
| 主规格 strict 校验 | 29/31 通过 | 25/26 通过 | 新增 2 项 invalid |
| 活跃提案 strict 校验 | 22/25 通过 | 18/18 通过 | 3 项 delta 工件结构问题 |
| macOS XCTest | 未复测（环境问题）| 409 通过/35 失败 | 未验证 |

## 三、架构合规性（按 AGENTS.md 检查清单）

| # | 检查项 | 结论 | 证据 |
|---|---|---|---|
| 1 | 业务逻辑只在 panda-core | ⚠️ 部分违规 | Swift 仍残留 4 处（见 §六） |
| 2 | FFI 薄桥接、同步导出、全局 runtime、密钥不经 FFI 落盘 | ✅ 通过 | `crates/panda-ffi/src/lib.rs` 顶层声明 + TransferService 已迁入 core |
| 3 | 依赖平台无关、Apache-2.0 兼容 | ⚠️ 未复测 | 9-11 报告 Linux gcc 缺口未复测 |
| 4 | 平台 `#if os()` 仅 UI/平台服务 | ✅ 通过 | Swift 端 grep 仅见窗口/工具栏差异 |
| 5 | 构建门禁 | ⚠️ 部分 | cargo test/llvm-cov 全绿；XCTest 未复测；未重跑 build-rust.sh→xcodegen→双端 xcodebuild |

## 四、自 9-11 以来归档的变更

| 归档变更 | 解决的问题 |
|---|---|
| 2026-09-22-thin-ffi-core-application | FFI 私有测试拆分、薄桥重构 |
| 2026-09-22-clean-test-only-code | 清理仅测试代码 |
| 2026-09-22-fix-ffi-test-coverage | FFI 测试覆盖率修复（关键） |
| 2026-09-19-add-tab-drag-sort-and-groups | 页签分组与拖拽 |
| 2026-09-20-redesign-tab-context-menu | 右键菜单重设计 |
| 2026-09-20-stabilize-workspace-tab-titles | 页签标题稳定化 |
| 2026-09-23-unify-upload-file-task-queue | **传输队列逐文件任务模型** |
| 2026-09-24-event-driven-connection-monitor | **连接监控事件驱动重构** |

## 五、活跃提案完成度分类（25 项实测）

| 类别 | 提案 | 完成度 |
|---|---|---|
| 已完成（5 项）| add-tab-switch-shortcut、fix-config-import-zip-slip、fix-tab-strip-intrinsic-width、harden-credential-file-permissions、remove-unreferenced-code | 100% |
| 主体完成（4 项）| terminal-mouse-interaction 18/31、use-alert-for-connection-close 8/10、fix-macos-tab-drag-and-titlebar-zoom 14/15、add-tab-close-and-quit-shortcuts 16/21 | 60-80% |
| 部分完成（6 项）| migrate-business-logic-to-rust 201/213、fix-settings-experience 28/36、add-app-internationalization 12/66、deepen-snippet-system 5/84、fix-ssh-session-failure-diagnostics 2/30、preserve-disconnected-session-tabs 1/15 | 7-94% |
| 未开始（10 项）| improve-sftp-task-interactions 2/26、improve-connection-reliability 0/80、add-ssh-proxy-jump 0/73、add-batch-remote-execution 0/47、add-manual-inspection-loop 0/50、tab-page-memory-indicator 0/8、terminal-buffer-size 0/9、add-command-audit-trail 0/22、add-execution-plan-authorization 0/18、refactor-macos-titlebar-tab-strip 0/13（待替代关闭）| <10% |

## 六、核心缺口清单

| 文件 | 问题 | 怎么改 | 改了以后影响什么 |
|---|---|---|---|
| `apple/PandaSSH/Workspace/TerminalSessionStore.swift` | 终端会话状态机仍 Swift（Phase 4 拖留），违反"业务逻辑只在 panda-core" | 完全下沉到 panda-core，Swift 仅保留视图绑定 | 解锁 migrate-business-logic-to-rust 归档；影响所有终端连接/重连/关闭路径 |
| `apple/PandaSSH/Workspace/ConnectionGate.swift#L48-L141` | TOFU 探测、tofuRegister/tofuAwaitOutcome/HostKeyMismatchError 仍 Swift | 与 panda-core/src/tofu.rs 的 TofuCoordinator 合并收口 | 影响 host key 流程与未知主机弹框时序；须重跑 TOFU 相关 XCTest |
| `apple/PandaSSH/Workspace/TransferStore.swift#L672-L833` | taskGroups/cancelGroup/retryGroup/pauseGroup/resumeGroup 仍 Swift 自实现 | 收口到 panda-core::task_aggregation + panda-ffi::task_aggregation | 解锁 rust-sftp-task-aggregation 归档；影响传输任务页所有组级操作 |
| `apple/PandaSSH/Workspace/SftpSessionStore.swift#L643-L647` | 选择逻辑与 900+ 行视图深度耦合，标注"无法安全移除" | 拆为独立后续提案 | 范围大，建议独立跟踪 |
| `openspec/changes/improve-sftp-task-interactions/tasks.md` | **仍 2/26**，最大缺口；删除核心、类型化 FFI、任务页、删除进度、右键选择、统一停机全部未动 | 完成任务 2.1-7.2，先统一任务类型/聚合/生命周期契约再补调用链 | 影响 SFTP 删除、应用停机、add-tab-close-and-quit-shortcuts 停机协调器 |
| `openspec/changes/migrate-business-logic-to-rust/tasks.md` | Phase 4 未完成（201/213）；config-archive 能力口径未决 | 完成剩余 12 项；明确 config-archive 是新建还是并入既有 | 影响 10 个能力 delta 合并；归档前必须修复受影响测试 |
| `openspec/specs/sftp-batch-transfer/spec.md#L385` | 主规格残留 `## ADDED Requirements` delta header（unify-upload-file-task-queue 归档时未清理） | 合并到主 `## Requirements` section，删 delta header | 修复主规格 strict 校验 invalid；恢复归档合并正确性 |
| `openspec/specs/transfers/spec.md#L336` | 同上，残留 `## ADDED Requirements` delta header | 同上 | 同上 |
| 3 项 next-release 提案 delta 工件 | add-ssh-proxy-jump、deepen-snippet-system、improve-connection-reliability 的 spec delta 写在单文件 `spec-deltas.md`，OpenSpec 无法解析 | 重构为 `specs/<capability>/spec.md` 目录结构 | 下一版本启动前必须修复，否则无法归档合并 |
| `panda-core/src/ssh.rs` | 覆盖率 regions 90.17% / lines 91.56%（低于 95%）| 补正常/失败/边界用例覆盖未测分支 | 提升 SSH 单文件覆盖率 |
| `panda-core/src/sftp.rs` | 覆盖率 regions 94.28% / lines 93.80%（低于 95%）| 同上 | 同上 |
| `panda-ffi/src/ffi_store.rs` | 覆盖率 regions 90.42% | 补 store 错误路径测试 | 提升 FFI store 单文件覆盖率 |
| macOS XCTest | 9-11 报告 35 项失败（7 个测试类），本轮复测因 SwiftBuildService 卡住未完成 | 修复环境后重跑 `xcodebuild test` | 不验证则不能视为当前版本归档完成 |

## 七、后续优先级

| 优先级 | 工作 | 完成判据 |
|---|---|---|
| P0 | 修复主规格 2 项 invalid（sftp-batch-transfer、transfers delta header 残留）| `openspec validate --specs --strict` 31/31 通过 |
| P0 | 重跑 macOS XCTest（环境修复后）确认 35 项失败是否随近期重构修复 | 退出码 0，全量通过 |
| P0 | 协同推进 improve-sftp-task-interactions + rust-sftp-task-aggregation + migrate-business-logic-to-rust 三提案收口 | Swift 业务逻辑全部下沉，三提案归档 |
| P0 | 完整产物重建链 build-rust.sh→xcodegen→双端 xcodebuild | macOS/iPadOS 双端构建通过 |
| P1 | iPadOS arm64 模拟器 XCTest 与 Swift 全应用覆盖率测量 | 有有效通过证据 |
| P1 | 3 项 next-release delta 工件重构（specs/<capability>/spec.md 目录）| `openspec validate` 全通过 |
| P2 | 补 ssh.rs、sftp.rs、ffi_store.rs 单文件覆盖率到 95% | 单文件 lines/regions ≥ 95% |
| P2 | 9 个 next-release 提案按依赖顺序启动（add-ssh-proxy-jump 优先，含 russh direct-tcpip spike）| 实施状态同步更新到 next-release.md |

## 八、亮点

- **覆盖率门禁从失败转为通过**（+3.87pp lines / +4.04pp regions），是本轮最大进展
- **基线三处冲突全部消解**：snippets 第 44 行说明性章节、config.yaml 凭据文件基线、connection-pool 所有者隔离
- **传输队列逐文件任务模型**（unify-upload-file-task-queue）与**连接监控事件驱动重构**（event-driven-connection-monitor）是架构级改进，为下一版本批量执行体系铺路
- 自 9-11 新增完成 5 个提案，migrate-business-logic-to-rust 从 199/207 推进到 201/213

## 九、风险

1. **Swift 业务逻辑残留 4 处**：违反 AGENTS.md 检查清单第 1 条，必须收口才能归档当前版本
2. **improve-sftp-task-interactions 卡在 2/26**：最大单提案缺口，涉及删除、停机、右键、任务页多个面
3. **macOS XCTest 未复测**：9-11 报告 35 项失败是否已修复未知；本轮环境问题导致 SwiftBuildService 卡住
4. **主规格 2 项新 invalid**：unify-upload-file-task-queue 归档时 delta header 未清理，归档流程需改进
5. **3 项 next-release delta 工件结构问题**：开始实施前必须重构
6. **iOS 平台未验证**：rusqlite bundled 静态链接、端口转发后台限制等需真机验证
