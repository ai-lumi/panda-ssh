# Spec Deltas：连接可靠性

## 变更概览

本提案新增 2 个规格文件，修订 4 个现有规格文件，覆盖会话持久化、自动重连和端口转发。

---

## 1. 新建 `openspec/specs/session-persistence/spec.md`

```markdown
# session-persistence Specification

## Purpose

工作区状态持久化：在 App 关闭前保存标签页结构，启动时恢复，使用户无需每次手动重建工作环境。

## Requirements

### Requirement: 工作区状态持久化

系统 SHALL 在标签页结构变化时（新建、关闭、重排）将当前工作区状态持久化到配置目录的 `workspace-state.toml`。状态 SHALL 包含每个标签页的主机 ID、标签类型、标签顺序、终端 PTY 尺寸和 SFTP 当前路径。状态 SHALL NOT 包含终端输出缓冲、shell 历史或文件列表缓存。

#### Scenario: 正常保存与恢复

- **GIVEN** 用户打开了两个终端标签和一个 SFTP 标签
- **WHEN** 用户关闭 App 后重新启动
- **THEN** 系统恢复三个标签页结构，自动发起连接

#### Scenario: 无保存状态

- **WHEN** 首次启动或 `workspace-state.toml` 不存在
- **THEN** 工作区显示空态，不报错

#### Scenario: 状态文件损坏

- **WHEN** `workspace-state.toml` 格式非法或字段缺失
- **THEN** 工作区显示空态，SHALL NOT 崩溃，MAY 记录警告日志

### Requirement: 用户配置

系统 SHALL 提供设置项 `restore_workspace_on_launch`（默认 `true`），控制是否在启动时恢复工作区。

#### Scenario: 关闭恢复

- **GIVEN** 用户关闭了 `restore_workspace_on_launch`
- **WHEN** App 启动
- **THEN** 工作区显示空态，不读取或恢复保存的状态

### Requirement: 平台一致性

工作区状态持久化 SHALL 在 macOS 和 iPadOS 上行为一致。业务逻辑在 Rust 核心实现，MUST NOT 使用平台条件编译引入业务分支。
```

---

## 2. 新建 `openspec/specs/port-forwarding/spec.md`

```markdown
# port-forwarding Specification

## Purpose

SSH 端口转发/隧道管理：支持本地转发、反向转发和动态转发（SOCKS5），按所有者独占连接，明确监听范围、生命周期和端口冲突处理。

## Requirements

### Requirement: 本地端口转发

系统 SHALL 支持本地端口转发（等效 `ssh -L`）。系统 SHALL 在本地指定地址:端口启动 TCP 监听，将接受的连接通过 SSH 隧道转发到远端指定地址:端口。

#### Scenario: 正常本地转发

- **GIVEN** 已建立 SSH 连接
- **WHEN** 用户创建本地转发：`127.0.0.1:8080` → `localhost:80`
- **THEN** 本地 `8080` 端口开始监听，连接到该端口的流量通过 SSH 隧道转发到远端 `localhost:80`

#### Scenario: 本地端口被占用

- **WHEN** 用户尝试绑定已被占用的本地端口
- **THEN** 返回 `PortConflict` 错误，SHALL NOT 静默选择其他端口

### Requirement: 反向端口转发

系统 SHALL 支持反向端口转发（等效 `ssh -R`）。系统 SHALL 通过 SSH `tcpip-forward` 请求在远端指定地址:端口启动监听，将远端接受的连接通过 SSH 隧道转发到本地指定地址:端口。

#### Scenario: 正常反向转发

- **GIVEN** 已建立 SSH 连接
- **WHEN** 用户创建反向转发：远端 `127.0.0.1:9090` → 本地 `localhost:3000`
- **THEN** 远端 `9090` 端口开始监听，远端连接到该端口的流量通过 SSH 隧道转发到本地 `localhost:3000`

#### Scenario: 服务端拒绝转发

- **WHEN** SSH 服务端因策略限制拒绝 `tcpip-forward` 请求
- **THEN** 返回明确错误，SHALL NOT 静默失败

### Requirement: 动态端口转发

系统 SHALL 支持动态端口转发（等效 `ssh -D`）。系统 SHALL 在本地指定地址:端口启动 SOCKS5 代理服务器，将 SOCKS CONNECT 请求通过 SSH 隧道转发到目标地址:端口。

#### Scenario: 正常 SOCKS5 代理

- **GIVEN** 已建立 SSH 连接
- **WHEN** 用户创建动态转发：`127.0.0.1:1080`
- **THEN** 本地 `1080` 端口启动 SOCKS5 代理，SOCKS CONNECT 请求通过 SSH 隧道转发到目标

#### Scenario: 非法绑定地址

- **WHEN** 用户尝试将动态转发绑定到 `0.0.0.0`
- **THEN** 系统拒绝请求并返回错误，MUST NOT 监听非回环地址

### Requirement: 端口转发所有权

每条端口转发 SHALL 关联一个所有者（标签页 ID 或独立任务 ID）。端口转发 SHALL 按所有者独占，MUST NOT 跨所有者共享 SSH Transport。

#### Scenario: 转发随标签页关闭

- **GIVEN** 终端标签 A 创建了一条本地转发
- **WHEN** 用户关闭标签页 A
- **THEN** 该转发被关闭，同主机其他标签页的转发不受影响

#### Scenario: 独立长生命周期转发

- **GIVEN** 用户创建了一条独立长生命周期的端口转发
- **WHEN** 用户关闭所有标签页
- **THEN** 该转发保持活动，在管理面板中可见可管理

### Requirement: 端口转发生命周期

端口转发 SHALL 支持三种生命周期模式：随标签页（转发随创建它的标签页存活）、随连接（转发随其独占的 SSH Transport 存活）、独立长生命周期（转发拥有自己的 SSH Transport）。

#### Scenario: 随连接生命周期

- **GIVEN** 一条随连接生命周期的转发
- **WHEN** 其 SSH Transport 被释放
- **THEN** 转发自动关闭

### Requirement: 监听范围约束

本地转发和动态转发的监听地址 SHALL 默认为 `127.0.0.1`。动态转发 MUST NOT 监听 `0.0.0.0`。本地转发允许用户选择 `0.0.0.0`，但 SHALL 显示安全风险提示。反向转发的远端监听范围由 SSH 服务端 `GatewayPorts` 配置决定。

#### Scenario: 默认监听地址

- **WHEN** 用户创建本地或动态转发且未指定绑定地址
- **THEN** 系统使用 `127.0.0.1` 作为默认绑定地址

### Requirement: 平台约束

端口转发业务逻辑 SHALL 在 Rust 核心实现。iPadOS 后台限制可能导致长时间后台时监听 Socket 被关闭，系统 SHALL 在 App 回到前台时检测并提示转发已失效。macOS 无此限制（App 退出后转发停止，非系统服务）。

#### Scenario: iPadOS 后台恢复

- **GIVEN** iPadOS 上有一条活动的端口转发
- **WHEN** App 长时间后台后回到前台
- **THEN** 系统检测转发状态，若已失效则显示提示并提供重建入口
```

---

## 3. 修订 `openspec/specs/ssh-connection/spec.md`

### 新增章节

在「命令执行」之后、「交互式 shell 会话」之前插入：

```markdown
### Requirement: 自动重连

系统 SHALL 支持终端标签在连接失效后按可配置策略自动重连。重连策略 SHALL 使用指数退避：初始间隔 1 秒、最大间隔 30 秒、最大重试次数默认 10 次、退避乘数 2.0。仅网络类错误（EOF、读写错误、keepalive 超时、连接超时）SHALL 触发自动重连；认证失败（`AuthFailed`）和主机密钥不匹配（`HostKeyMismatch`）SHALL NOT 触发自动重连。

每次重连 SHALL 重新从凭据存储获取凭据，MUST NOT 使用内存缓存的旧凭据。重连 SHALL 重新执行主机密钥检查，密钥变更时阻断并告警。重连成功后 SHALL 重建 shell Channel 并恢复 PTY 尺寸。

#### Scenario: 网络中断后自动重连

- **GIVEN** 终端标签处于已连接状态，自动重连已启用
- **WHEN** 网络中断导致连接失效
- **THEN** 系统自动开始重连，显示重连状态，成功后恢复交互

#### Scenario: 达到最大重试次数

- **GIVEN** 自动重连已进行 10 次尝试均失败
- **WHEN** 第 10 次重试失败
- **THEN** 系统停止自动重连，显示失败状态和手动重试入口

#### Scenario: 认证失败不触发重连

- **WHEN** 连接因凭据错误导致 `AuthFailed`
- **THEN** 系统直接进入失败状态，SHALL NOT 触发自动重连

#### Scenario: 用户取消重连

- **GIVEN** 系统正在自动重连
- **WHEN** 用户点击取消
- **THEN** 系统停止重连，进入失败状态
```

---

## 4. 修订 `openspec/specs/connection-pool/spec.md`

### 新增章节

在「连接生命周期遥测」之后插入：

```markdown
### Requirement: 重连期间所有权保持

终端标签的自动重连 SHALL 为该标签建立新 Transport，MUST NOT 复用其他所有者的连接。重连期间旧 Socket SHALL 已释放，同主机其他标签页的连接状态 SHALL 不受影响。

#### Scenario: 重连不影响其他标签

- **GIVEN** 同一主机有两个终端标签，标签 A 开始自动重连
- **WHEN** 标签 A 正在重连过程中
- **THEN** 标签 B 的连接保持正常，SHALL NOT 被标签 A 的重连流程影响
```

---

## 5. 修订 `openspec/specs/shell-terminal/spec.md`

### 新增章节

在「终端单飞重试」之后插入：

```markdown
### Requirement: 重连后 PTY 恢复

自动重连成功建立新 shell Channel 后，系统 SHALL 恢复重连前的 PTY 窗口尺寸（列数和行数）。恢复 SHALL 在新 shell 建立后立即发送 `window-change` 请求。

#### Scenario: 重连后恢复窗口尺寸

- **GIVEN** 终端标签窗口尺寸为 120×40，连接失效后自动重连
- **WHEN** 重连成功并建立新 shell
- **THEN** 系统立即发送 `window-change` 请求，将远端 PTY 设为 120×40
```

---

## 6. 修订 `openspec/specs/workspace/spec.md`

### 新增章节

在「主内容区空态」之后插入：

```markdown
### Requirement: 工作区状态恢复

系统 SHALL 在启动时读取持久化的工作区状态，恢复标签页结构并自动发起连接。恢复 SHALL 受 `restore_workspace_on_launch` 设置控制。状态文件不存在或损坏时 SHALL 显示空态，MUST NOT 崩溃。

#### Scenario: 启动时恢复标签页

- **GIVEN** 上次关闭时有两个终端标签和一个 SFTP 标签
- **WHEN** App 启动且 `restore_workspace_on_launch` 为 `true`
- **THEN** 恢复三个标签页结构并自动发起连接

#### Scenario: 恢复设置关闭

- **GIVEN** `restore_workspace_on_launch` 为 `false`
- **WHEN** App 启动
- **THEN** 显示空态，不恢复标签页
```

---

## 影响分析

### 兼容性

- **会话持久化**：新增能力，不改变现有行为
- **自动重连**：扩展现有重连行为（从手动重试到自动重试），不改变手动重试流程
- **端口转发**：全新能力，不影响现有连接和标签页行为
- **连接所有权**：保持所有者独占设计，不引入全局池

### 测试影响

- 新增大量单元测试：重连策略、端口转发、工作区状态
- 集成测试：使用 fake SSH server 模拟断线和重连
- 覆盖率要求：95% 行覆盖和区域覆盖

### 文档影响

- 新增 2 个 spec 文件
- 修订 4 个 spec 文件
- 路线图 1.4 相关缺口标记为已处理

---

## 迁移指南

### 现有用户

- 工作区状态持久化默认启用，首次启动时无保存状态，显示空态
- 自动重连默认启用（最大重试 10 次），用户可在设置中调整参数或关闭
- 端口转发为全新功能，无迁移影响

### 配置迁移

- 新增 `workspace-state.toml`（自动生成，无需手动创建）
- 新增 `reconnect_policy` 配置项（可选，使用默认值时无需配置）
- 新增 `session_restore_command` 主机配置项（可选）
