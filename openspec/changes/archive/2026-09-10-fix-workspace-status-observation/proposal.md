## Why

SSH 会话连接成功后页签仍显示黄色，输入 `exit` 后仍显示绿色。`WorkspaceStore.reportConnectionStatus` 已更新 Rust 状态，但没有发出 SwiftUI 观察通知；页签与侧栏只有在其他事件触发重绘后才读到新状态。

## What Changes

- 在工作区实际连接状态变化时通知 SwiftUI，使页签与侧栏在下一次界面更新中读取最新状态。
- 重复状态、未知页签及已关闭页签的延迟回调保持无操作，避免无效重绘。
- 先以真实工作区 FFI 和 Combine 观察测试复现，再补充最小实现。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无。恢复 `workspace` 的「多标签页工作区」当前状态展示要求及 `shell-terminal` 的远端退出语义；`skip_specs: true`，不改变既有规范，不创建规格增量。

## Impact

仅涉及双端共享的 `WorkspaceStore` UI 通知桥接与 XCTest。Rust 继续拥有状态及主机聚合规则，保留现有颜色、FFI 契约和会话生命周期。
