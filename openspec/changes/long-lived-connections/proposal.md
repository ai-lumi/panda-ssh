# Proposal: 移除连接池空闲超时，改为长连接 + 显式断开

## Summary

将 SSH/SFTP 连接管理从「连接池 + 30 秒空闲超时回收」改为「长连接缓存 + 显式断开」。连接在用户显式关闭最后一个指向同一主机的标签页之前持久存活，切换 tab 不会触发断开。

## Motivation

当前连接池有 30 秒空闲超时。用户切换 tab 超过 30 秒后，底层 SSH 连接被后台任务回收，切回时需要重新握手，体验差且增加服务器负载。桌面 SSH 客户端的连接生命周期应由 UI 标签页驱动，而非时间超时。

## Changes

- **移除** `ConnectionPool` 的 `IDLE_TIMEOUT`、`CHECK_INTERVAL` 常量与 `start_cleanup_task` / `cleanup_stale_entries` 方法；`global_pool()` 不再启动后台回收任务。
- **新增** `ConnectionPool::disconnect_host(host_id)` 方法，按 host_id 移除池中该主机的全部会话条目。
- **新增** FFI 导出 `disconnect_host(host_id: String)`，供 Swift 在关闭最后一个指向某主机的标签页时调用。
- **修改** Swift 侧 `WorkspaceStore`：关闭标签页时检查是否还有同主机标签，若无则调用 `disconnect_host`。
- **保留** 连接复用（`get_or_create` 含惰性存活检测）与多路频道复用能力不变。

## Risks

- 连接不再自动回收，若用户打开大量不同主机的标签页后逐一关闭但不退出 app，连接可能堆积。通过显式断开缓解。
- `disconnect_host` 移除池条目后，若有正在进行的 SFTP 操作持有 `Arc<SshSession>`，会话不会立即断开，但下一次操作会新建连接。可接受。
