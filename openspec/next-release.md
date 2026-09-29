# OpenSpec 版本文件

## v1.0.0（已实现）

完整的已实现规格合订本，涵盖 `openspec/specs/` 下所有已归档 changes 和活跃 1.0.0 changes 的累积结果。

- **文件**：[v1.0.0-specs.md](v1.0.0-specs.md)
- **基准**：`openspec/specs/`
- **包含的活跃 changes 合并**：add-tab-close-and-quit-shortcuts、fix-macos-tab-drag-and-titlebar-zoom、fix-settings-experience、fix-initial-terminal-size-sync、migrate-business-logic-to-rust、terminal-mouse-interaction、use-alert-for-connection-close

## v1.1.0（规划中）

v1.1.0 版本规划新增或修改的规格，基于活跃 changes 中的 spec delta 整理，尚未开始实施或部分实施中。

- **文件**：[v1.1.0-specs.md](v1.1.0-specs.md)
- **纳入的 changes**：add-app-internationalization、add-batch-remote-execution、add-command-audit-trail、add-execution-plan-authorization、add-manual-inspection-loop、preserve-disconnected-session-tabs、refactor-macos-titlebar-tab-strip、refactor-sftp-view-selection、tab-page-memory-indicator、terminal-buffer-size、fix-ssh-session-failure-diagnostics、**add-ssh-proxy-jump**（从 archive 复活）、**add-port-forwarding**（新建）

> 注 1：v1.1.0 中的 `terminal-buffer-size` change 与 v1.0.0 已合并的 `fix-settings-experience` 版本存在差异（v1.1.0 新增内存占用估算，v1.0.0 明确禁止）；实施前需裁决。
> 注 2：proxy-jump 和 port-forwarding 已创建正式 change 提案（见 `openspec/changes/add-ssh-proxy-jump/` 和 `openspec/changes/add-port-forwarding/`），包含完整 proposal/design/tasks/specs。两者共享 `DirectTcpipChannel` 流包装，建议先做 proxy-jump。
> 注 3：add-ssh-proxy-jump 和 add-port-forwarding 的 Phase 0 都是 russh direct-tcpip / tcpip-forward API 验证（spike），如果 spike 失败需升级 russh 版本。

## 原始 changes 目录

所有活跃 changes 仍在 `openspec/changes/` 下独立维护；本文件仅作为导航入口，不替代各 change 自身的 proposal/design/tasks。
