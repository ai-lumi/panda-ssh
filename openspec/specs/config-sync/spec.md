# config-sync Specification

## Purpose

macOS 与 iPadOS 之间共享配置与凭据：主机配置经 iCloud Key-Value Storage 同步，密码与私钥口令经 iCloud 同步钥匙串漫游。本期为骨架：提供 push/pull 原语，变更监听与冲突合并属于后续变更。
## Requirements
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

### Requirement: 本地存储位置

两平台的本地配置文件 MUST 落在 App Group 容器 `group.com.pandassh.shared` 下（不可用时回退 Documents），路径由 App 注入 Rust 核心。

#### Scenario: 容器不可用回退

- **WHEN** App Group 容器路径不可得（如未配置签名的开发构建）
- **THEN** 使用 Documents 目录，功能不受影响

### Requirement: 配置同步行为

系统 SHALL 基于 `NSUbiquitousKeyValueStore` 同步配置快照：hosts.toml 与 groups.toml 序列化为一枚版本化 KV 值（含 `version` 与 `updatedAt` 写入时间戳）。保存或删除主机、调整分组后 MUST 自动 push 最新快照；App 启动时 MUST pull 远端快照并在本地为空或远端 `updatedAt` 更新时应用；`startObserving` 监听远端变更，收到后 MUST 落盘并刷新主机列表。冲突策略为 last-write-wins：以 `updatedAt` 时间戳判定，后写入者生效；时间戳相等时以本地为准。应用远端变更的落盘 MUST 抑制由此触发的本地 push，防止同步回环。KV store 实现 SHALL 可注入以便测试。

#### Scenario: 保存主机后自动推送

- **WHEN** 用户保存或删除一台主机
- **THEN** 最新配置快照被 push 到 iCloud KV

#### Scenario: 远端变更生效

- **WHEN** 另一台设备 push 了新配置，本机收到变更通知
- **THEN** 本机 hosts.toml 被更新且主机列表刷新

#### Scenario: 分组随配置同步

- **WHEN** 一端调整了分组结构
- **THEN** 另一端分组结构自动更新

#### Scenario: 并发修改后最终一致

- **GIVEN** 两台设备同时修改同一配置
- **WHEN** 双方同步完成
- **THEN** 两端最终收敛到 `updatedAt` 较新的版本，配置文件保持完整可读

#### Scenario: 应用远端变更不回环

- **WHEN** 本机应用远端推送的快照并落盘
- **THEN** 本次落盘不触发新的 push

### Requirement: 离线可用

配置 SHALL 始终落盘于 App Group 容器（本地文件），iCloud KV 仅作为同步载体；iCloud 不可用时本地功能 MUST 保持可用。

#### Scenario: iCloud 不可用时本地仍可用

- **GIVEN** 设备未登录 iCloud 或 KV 不可用
- **WHEN** 用户查看/编辑主机
- **THEN** 本地主机配置完整可用，仅跨设备同步暂停

### Requirement: 密钥材料不同步

密码、私钥口令等密钥材料 MUST NOT 通过 KV 同步；同步内容仅允许配置与钥匙串引用标识，明文密钥 MUST NOT 出现。

#### Scenario: KV 快照不含密钥材料

- **GIVEN** 用户已保存密码与私钥口令
- **WHEN** 检查同步快照内容
- **THEN** 快照中不含任何明文密码或口令，仅含钥匙串引用

### Requirement: 私钥路径按设备独立

`AuthMethod::PublicKey.key_path` 指向本机文件系统路径，私钥文件不随同步漫游；应用远端快照时 MUST NOT 用它端写入的 `key_path` 覆盖本机值，各端独立设置。

#### Scenario: 同步不覆盖本机私钥路径

- **GIVEN** 本机已为某主机配置私钥路径
- **WHEN** 应用远端快照
- **THEN** 本机 `key_path` 保持本机值，不被远端值覆盖

#### Scenario: 未设置私钥的设备报错引导

- **GIVEN** 某主机在另一端配置了密钥认证，而本机未设置私钥
- **WHEN** 本机连接该主机
- **THEN** 系统提示用户选择本机私钥，而非使用无效路径

### Requirement: 主机密钥信任不同步

known_hosts 的主机密钥信任记录 MUST NOT 纳入同步；每台设备 SHALL 独立执行首次连接指纹确认（TOFU）。

#### Scenario: 各端独立确认指纹

- **GIVEN** 用户已在 Mac 上信任某主机指纹
- **WHEN** 在 iPad 上首次连接该主机
- **THEN** iPad 仍弹出指纹确认对话框

