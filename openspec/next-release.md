# 下一版本范围

> 决策日期：2026-09-11｜目标版本号：待定｜实施状态：未开始。

本文件记录下一版本的提案范围；功能细节与验收要求见各提案，系统当前行为仍以 `openspec/specs/` 为准。

## 纳入的提案

| 提案 | 新增能力 | 实施状态 |
| --- | --- | --- |
| [add-ssh-proxy-jump](changes/add-ssh-proxy-jump/proposal.md) | SSH 单跳／多跳跳板机 | 未开始 |
| [deepen-snippet-system](changes/deepen-snippet-system/proposal.md) | 多级标签、搜索、终端选文保存、参数化模板 | 未开始 |
| [improve-connection-reliability](changes/improve-connection-reliability/proposal.md) | 会话恢复、自动重连、端口转发 | 未开始 |
| [add-command-audit-trail](changes/add-command-audit-trail/proposal.md) | 命令与 SFTP 审计、缺段检查 | 未开始 |
| [add-execution-plan-authorization](changes/add-execution-plan-authorization/proposal.md) | 执行计划、审批与授权生命周期 | 未开始 |
| [add-batch-remote-execution](changes/add-batch-remote-execution/proposal.md) | 多主机批量执行与结果保存 | 未开始 |
| [add-manual-inspection-loop](changes/add-manual-inspection-loop/proposal.md) | 人工触发巡检、指标采集和报告 | 未开始 |
| [terminal-buffer-size](changes/terminal-buffer-size/proposal.md) | 终端缓冲区配置与设置时的内存估算 | 未开始 |
| [tab-page-memory-indicator](changes/tab-page-memory-indicator/proposal.md) | 标签页内存估算与展示 | 未开始 |

## 范围决策与状态口径

- 用户明确下一版本尚未开始实施；2026-09-11 在前七项计划的基础上，将 `terminal-buffer-size` 与 `tab-page-memory-indicator` 一并纳入，共九项。
- `deepen-snippet-system` 已勾选的五项是既有 CRUD、前置条件和设计决策，不代表深化功能已开始实施。
- 当前版本归档检查时，上述九项按下一版本计划处理；其未实施任务不计入当前版本的归档欠账。
- 纳入版本表示排期范围已确定。实施时仍须完成提案评审、TDD 与相应验收；开始实施后同步更新本清单和对应任务记录。
