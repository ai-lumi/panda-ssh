# Design: 长连接 + 显式断开

## 决策

### 1. 移除空闲超时，保留连接缓存

`ConnectionPool` 保留 `(host_id, credentials) → Arc<SshSession>` 的 HashMap 缓存，用于同一主机多标签页共享连接。移除 30 秒空闲超时和后台扫描任务。连接仅在以下情况被移除：

- 显式调用 `disconnect_host(host_id)`（用户关闭最后一个同主机标签页）
- 连接失效检测（`get_or_create` 中的惰性 `open_channel()` 检测失败时自动移除并重建）

### 2. disconnect_host 行为

```rust
pub async fn disconnect_host(&self, host_id: &str) {
    let mut entries = self.entries.lock().await;
    entries.retain(|key, _| key.host_id != host_id);
}
```

移除池中该 host_id 的全部条目。若此时有其他代码持有 `Arc<SshSession>`（如正在执行的 SFTP 操作），会话不会立即断开；当最后一个 `Arc` 被 drop 时，`SshSession` 的 `Drop` 实现断开 TCP 连接。

### 3. Swift 侧生命周期管理

`WorkspaceStore.close(tabID:)` 在移除标签后检查是否还有同 hostID 的标签存活：

```swift
func close(tabID: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    let hostID = tabs[index].hostID
    // ... 移除标签 ...
    // 若无同主机标签，显式断开 SSH 连接
    if !tabs.contains(where: { $0.hostID == hostID }) {
        try? disconnectHost(hostId: hostID)
    }
}
```

同样适用于 `closeTabs(forHostID:)`（删除主机级联清理）。

### 4. 不变的部分

- `get_or_create` 的惰性存活检测保留（`open_channel()` 探测）
- `ShellSession` 持有 `Arc<SshSession>` 不变
- SFTP 操作通过 `get_or_create_session` 复用连接不变
- 线程安全（`tokio::sync::Mutex`）不变
