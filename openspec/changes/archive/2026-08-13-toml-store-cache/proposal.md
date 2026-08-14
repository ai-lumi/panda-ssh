# TOML Store Cache

## Why

`TomlConfigStore` 与 `TomlGroupStore` 的每个操作（get/list/upsert/delete）都重新读取并解析整个 TOML 文件。同一实例内连续操作（如列表后按 id 查找）造成重复磁盘 I/O 与解析开销。

## What Changes

- `TomlConfigStore` 增加实例级 `Vec<HostConfig>` 缓存
- `TomlGroupStore` 增加实例级 `Vec<Group>` 缓存
- `read()` 命中缓存时直接返回克隆，跳过文件读取与 TOML 解析
- `write()` 成功落盘后同步更新缓存

## Capabilities

无 spec 级行为变更；纯实现优化，skip_specs。

## Impact

- `crates/panda-core/src/config.rs`
- `crates/panda-core/src/groups.rs`
