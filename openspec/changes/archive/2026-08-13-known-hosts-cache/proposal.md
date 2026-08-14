# Known Hosts Cache

## Why

`KnownHosts::check` 与 `status` 每次调用都重新读取并解析整个 `known_hosts` 文件。同一次 SSH 连接中（FFI `test_connection` 或连接池获取会话）这两个方法通常会被先后调用，造成重复磁盘 I/O。

## What Changes

- `KnownHosts` 增加实例级缓存，以文件 mtime 为失效标记
- `load()` 优先返回缓存；mtime 变化或文件被删除时重新读取
- `store()` 与 `remove()` 在写盘后清除缓存，确保下次读取最新内容

## Capabilities

无 spec 级行为变更；纯实现优化，skip_specs。

## Impact

- `crates/panda-core/src/hostkey.rs`
