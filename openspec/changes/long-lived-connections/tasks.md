# Tasks: 长连接 + 显式断开

## 1. Rust 核心

- [ ] 移除 `connection_pool.rs` 中 `IDLE_TIMEOUT`、`CHECK_INTERVAL` 常量
- [ ] 移除 `start_cleanup_task`、`cleanup_stale_entries` 方法
- [ ] `global_pool()` 不再调用 `start_cleanup_task()`
- [ ] 新增 `disconnect_host(host_id: &str)` 方法，按 host_id 移除全部条目
- [ ] 更新模块文档注释
- [ ] 更新 / 移除空闲超时相关测试，新增 `disconnect_host` 测试

## 2. FFI 层

- [ ] 新增 `#[uniffi::export] pub fn disconnect_host(host_id: String)` 导出
- [ ] 重新生成 Swift 绑定

## 3. Swift 层

- [ ] `WorkspaceStore.close(tabID:)` 关闭最后一个同主机标签时调用 `disconnectHost`
- [ ] `WorkspaceStore.closeTabs(forHostID:)` 同样调用 `disconnectHost`

## 4. OpenSpec

- [ ] 更新 `connection-pool` spec：移除空闲超时 requirement，新增显式断开 requirement

## 5. 验证

- [ ] `cargo test -p panda-core` 全绿
- [ ] `cargo check --workspace` 通过
- [ ] `build-rust.sh` + `xcodegen` 成功
