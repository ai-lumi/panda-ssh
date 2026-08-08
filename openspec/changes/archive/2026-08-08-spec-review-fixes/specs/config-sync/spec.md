# config-sync Spec Delta

## REMOVED Requirements

### Requirement: 配置同步原语

**Reason**: 原语已接线为完整同步行为，由「配置同步行为」取代。
**Migration**: push/pull/startObserving 原语语义并入新 Requirement。

## ADDED Requirements

### Requirement: 配置同步行为

系统 SHALL 基于 `NSUbiquitousKeyValueStore` 同步 hosts.toml：保存或删除主机后 MUST 自动 push 最新配置；App 启动时 MUST pull 远端配置并在本地为空或远端更新时应用；`startObserving` 监听远端变更，收到后 MUST 落盘并刷新主机列表。本期冲突策略为 last-write-wins（以 iCloud 为准覆盖本地），冲突合并属后续 config-sync 变更。KV store 实现 SHALL 可注入以便测试。

#### Scenario: 保存主机后自动推送

- **WHEN** 用户保存或删除一台主机
- **THEN** 最新 hosts.toml 被 push 到 iCloud KV

#### Scenario: 远端变更生效

- **WHEN** 另一台设备 push 了新配置，本机收到变更通知
- **THEN** 本机 hosts.toml 被更新且主机列表刷新

## MODIFIED Requirements

### Requirement: 凭据漫游

密码与私钥口令 MUST 存入 `kSecAttrSynchronizable = true` 的钥匙串条目，配置文件 SHALL 只存引用 key。单 App 场景 SHALL NOT 设置显式 `kSecAttrAccessGroup`（避免 Team ID 前缀耦合；跨设备漫游依赖 synchronizable 而非访问组）。钥匙串写入失败 MUST 以错误呈现给用户并阻止保存，SHALL NOT 静默丢失凭据。删除主机时 MUST 级联删除其关联的钥匙串条目（密码与口令引用）。

#### Scenario: 新增主机保存密码

- **WHEN** 用户在编辑表单中填写密码并保存
- **THEN** 密码进入同步钥匙串，hosts.toml 中仅出现引用 key

#### Scenario: 钥匙串写入失败

- **WHEN** 保存时钥匙串写入失败
- **THEN** 用户看到错误提示，主机配置不被保存

#### Scenario: 删除主机清理凭据

- **WHEN** 用户删除一台主机
- **THEN** 其 `host.<id>.password` / `host.<id>.passphrase` 钥匙串条目被一并删除
