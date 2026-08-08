## Context

现有实现：`TomlConfigStore`（`hosts.toml`，原子写）与 FFI 的 `list_hosts`/`save_host`/`delete_host` 已覆盖主机 CRUD；`KnownHosts`（known_hosts 文件）支持 `check`（Match/Mismatch/Unknown）与 `store`。`SshSession::connect` 接受 `UnknownHostKeyPolicy`，core 有 `Reject` 与 `AcceptAndStore` 两策略，但 FFI 的 `connect_host` 硬编码为 `AcceptAndStore`，且 UI 没有任何确认入口——这正是本变更要解决的缺口。

## Goals / Non-Goals

**Goals:**

- 主机管理在双端有完整可用 UI。
- 用户能查看某主机的已记录指纹，并在首次连接未知主机时确认指纹。
- 密钥不一致时阻断连接并给出明确告警。
- FFI 把「是否信任未知密钥」的决策权交还 UI（Swift）。

**Non-Goals:**

- 实现 known_hosts 手动编辑、批量导入导出。
- 实现分组（另立变更）。
- 实现密码/密钥保存 UI（另立变更）。
- 改变 known_hosts 文件的格式（沿用 OpenSSH `known_hosts` 行格式）。

## Decisions

### 连接前询问：状态查询 + Reject 探测取指纹

新增 FFI 导出 `host_key_status(host, port) -> KnownHostStatus`（`Unknown`/`Match`/`Mismatch`），Swift 侧在发起连接前调用：

- `Match` → 直接连接。
- `Mismatch` → 阻断并展示「密钥已变更」告警，不提供一键信任覆盖（风险高，留待后续）。
- `Unknown` → 以 `Reject` 策略发起一次连接探测：core 在校验阶段拒绝并返回 `UnknownHostKey`（主 spec「连接期策略」已规定该错误 MUST 携带服务端呈现的密钥与指纹）→ UI 用错误中的指纹弹确认框；「信任」则调用 `accept_unknown_host_key(host, port, key)` 把**本次探测呈现的密钥**写入 known_hosts，再正常重连（此时判定为 Match，直接放行）；「取消」则放弃。

要点：Unknown 主机在 known_hosts 中没有记录，指纹只能来自一次真实握手，`host_key_status` 无法提供指纹。存储探测时呈现的密钥（而非信任后二次连接时由 `AcceptAndStore` 顺手存储），避免两次握手之间密钥被替换的 TOCTOU 窗口。

连接入口（`test_connection`/`sftp_*`）新增 `trust_on_first_use: bool` 参数：`false`（UI 默认）用 `Reject`，`true` 用 `AcceptAndStore`（保留给自动化或未来「始终信任」选项）。这样把「确认」与「连接」解耦，避免在连接回调里做异步弹窗。`shell_open` 由 tabbed-workspace 变更引入，其签名按同一约定带 `trust_on_first_use`；本变更只改造既有连接入口。

### 指纹确认的并发串行化

「同一主机仅确认一次」在 Swift 侧实现：工作区维护按主机的待确认表（hostId → 等待中的连接续体列表）。某主机已有确认对话框在展示时，后续对该主机的连接请求只挂入等待列表，不再弹框；用户作出选择后把结果广播给全部等待者——信任则各自继续（此时 known_hosts 已是 Match，直接放行），取消则各自终止。core/FFI 无需感知并发，不用改动。

### 指纹展示与格式

`host_key_status` 返回 OpenSSH 格式指纹（如 SHA256 冒号分隔）与算法类型。UI 以 monospace 展示完整指纹，避免复制错误。

### 并发与文件锁

`KnownHosts` 每次调用重新读文件（与现有 `check_server_key` 行为一致），写入用 temp + rename 原子替换，避免并发会话互相覆盖。

### 配置持久化目录

macOS 桌面端配置文件落盘到用户主目录下的 `~/.panda-ssh/`（`hosts.toml`、`groups.toml`、`known_hosts`），便于用户查看、备份及与命令行工具集成；为允许自由读写该目录，macOS 关闭 App Sandbox。iPadOS 受沙盒限制，仍使用 App Group 共享容器（`group.com.pandassh.shared`）。`AppPaths.configDirectory` 按平台分支，`init_store(config_dir)` 由 Swift 侧注入对应路径。

### 主机表单

`HostEditView.swift` 扩展：地址/端口/用户名/认证方式/备注/所属分组；保存走 `save_host`（空 id 生成 UUID，现有 FFI 已支持）。「所属分组」字段依赖 `server-groups` 变更的 `list_groups` FFI 与 groups.toml——实施顺序上 server-groups 先行；若其未落地，表单先隐藏分组字段，主机的 `group_id` 持久化语义由 server-groups 定义。

## Risks / Trade-offs

- [把确认决策移到 UI 层后，无人值守/自动化连接会失败] → 这是安全优先的取舍；连接入口显式传 `trust_on_first_use`，后续可按需开放「始终信任」选项。
- [`Mismatch` 阻断会打断合法的主机密钥轮换] → 提供告警文案提示管理员核对，后续可加「手动更新指纹」能力。
- [指纹确认依赖 UI 状态，测试覆盖变复杂] → 把「状态查询→确认→连接」拆成独立 FFI 调用，core 层各环节可单测，Swift 层只测对话框状态机。

## Migration Plan

无数据迁移。既有 known_hosts 文件继续使用；仅连接入口的行为策略发生变化（需要用户确认），已在提案 Impact 中说明同步更新 AGENTS.md 的描述。

## Open Questions

- 密钥变更（`Mismatch`）场景是否要提供「删除旧指纹后重新确认」入口？当前 Non-Goal，按告警处理，后续根据反馈补充。
