# 设计：连接可靠性

## 1. 三层恢复语义

按路线图 1.4 要求，分开定义工作区恢复、SSH 重连与远端进程恢复，各自承诺不同层次的恢复能力。

### 1.1 工作区 UI 恢复

**承诺**：App 重启后恢复标签页结构和配置。

- 持久化每个标签页的：主机 ID、标签类型（终端/SFTP）、标签顺序、PTY 尺寸（终端标签）、当前路径（SFTP 标签）。
- 持久化位置：配置目录下的 `workspace-state.toml`。
- 恢复时机：App 启动时读取，重建标签页结构，自动发起连接。
- 不持久化：终端输出缓冲、shell 历史、SFTP 文件列表缓存。
- 用户可关闭此功能（设置项 `restore_workspace_on_launch: bool`，默认 `true`）。

**不承诺**：恢复后的连接一定成功。凭据失效、主机不可达等情形走正常连接失败流程。

### 1.2 SSH 传输重连

**承诺**：终端标签检测到连接失效后，按策略自动重建 SSH Transport。

- 检测手段：EOF、Socket 读写错误、SSH keepalive 连续失败、通道打开失败（复用现有 `connection-pool/spec.md` 的失效检测）。
- 重连策略：指数退避，初始间隔 1 秒，最大间隔 30 秒，最大重试次数可配置（默认 10 次）。
- 重连期间：终端标签显示重连状态（"正在重连... 第 N 次尝试，等待 Xs"），保留终端输出缓冲。
- 重连成功后：重建 SSH Transport + 新 shell Channel，恢复 PTY 尺寸。
- 重连失败后（达到最大次数）：显示失败状态和手动重试按钮。

**不承诺**：重连后远端 shell 会话内容保留。新 shell 是全新会话，不恢复旧 shell 的环境变量、工作目录或运行中进程。

### 1.3 远端进程恢复

**承诺**：仅当用户使用 tmux/screen 等远端多路复用器时，新 shell 可附加到已有会话。

- 系统不主动安装或启动 tmux/screen。
- 系统可在重连后自动发送用户配置的「恢复命令」（如 `tmux attach -t main || tmux new -t main`），此命令在主机配置中可选设置（`session_restore_command: Option<String>`）。
- 恢复命令在重连成功建立新 shell 后执行，等同于用户手动输入。

**不承诺**：无辅助的远端进程恢复。没有 tmux/screen 时，重连后是全新 shell，旧进程状态丢失。

## 2. 自动重连策略

### 2.1 状态机

```
已连接 ──检测失效──→ 重连中 ──成功──→ 已连接
  ↑                    │
  │                    ├──失败且未达上限──→ 等待退避 ──→ 重连中
  │                    │
  │                    └──达到上限──→ 重连失败
  │                                    │
  └──────────── 用户手动重试 ──────────┘
```

### 2.2 退避参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `initial_backoff_secs` | 1 | 首次重连等待秒数 |
| `max_backoff_secs` | 30 | 最大退避间隔 |
| `max_retries` | 10 | 最大重试次数（0 = 不自动重连） |
| `backoff_multiplier` | 2.0 | 退避乘数 |

退避公式：`min(initial_backoff * multiplier^(n-1), max_backoff)`，其中 n 为当前重试序号。

### 2.3 重连安全约束

- **凭据获取**：每次重连重新从凭据存储读取密码/口令，不使用内存缓存的旧凭据。凭据不可用时停止重连并显示明确错误。
- **主机密钥**：重连走与首次连接相同的主机密钥检查流程。密钥变更时阻断重连并显示告警（与现有 `HostKeyMismatch` 行为一致）。
- **用户取消**：用户在重连过程中可手动取消，停止重试并进入失败状态。
- **非可重连错误**：认证失败（`AuthFailed`）、主机密钥不匹配（`HostKeyMismatch`）不触发自动重连，直接进入失败状态。仅网络类错误（EOF、读写错误、keepalive 超时、连接超时）触发自动重连。

### 2.4 所有者独占保持

重连为同一标签页/所有者建立新 Transport，不复用其他所有者的连接。重连期间该标签页的旧 Socket 已释放，不影响同主机其他标签页。

## 3. 端口转发模型

### 3.1 转发类型

| 类型 | SSH 等效 | 监听位置 | 转发方向 |
|------|----------|----------|----------|
| 本地转发 | `-L` | 本地地址:端口 | 通过 SSH 隧道 → 远端地址:端口 |
| 反向转发 | `-R` | 远端地址:端口 | 通过 SSH 隧道 → 本地地址:端口 |
| 动态转发 | `-D` | 本地地址:端口 | SOCKS5 代理 → 通过 SSH 隧道 → 任意远端 |

### 3.2 数据模型

```rust
/// 端口转发配置
pub struct PortForwardConfig {
    pub id: Uuid,
    pub owner_id: OwnerId,  // 所有者标识（标签页 ID 或任务 ID）
    pub kind: ForwardKind,
    pub bind_address: String,
    pub bind_port: u16,
    pub remote_address: String,  // 动态转发时为空
    pub remote_port: u16,        // 动态转发时为 0
}

pub enum ForwardKind {
    Local,
    Remote,
    Dynamic,
}

/// 端口转发状态
pub enum ForwardState {
    Pending,      // 等待建立
    Active,       // 监听中
    Failed(String), // 失败原因
    Closed,       // 已关闭
}
```

### 3.3 生命周期

端口转发按所有者独占，三种生命周期模式：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| 随标签页 | 转发随创建它的终端/SFTP 标签页存活，标签页关闭时转发关闭 | 临时调试 |
| 随连接 | 转发随其独占的 SSH Transport 存活，Transport 释放时转发关闭 | 默认模式 |
| 独立长生命周期 | 转发拥有自己的 SSH Transport，不依附于任何标签页 | 持久隧道 |

独立长生命周期的转发在「端口转发管理面板」中展示和管理，用户可手动关闭。

### 3.4 端口冲突处理

- 绑定前检查本地端口可用性。
- 端口被占用时返回 `PortConflict { port, address }` 错误，不静默选择其他端口。
- 反向转发的远端端口冲突由 SSH 服务端返回错误，客户端捕获并展示。
- 用户可选择 `bind_address`（`127.0.0.1`、`0.0.0.0`、`::1` 等），默认 `127.0.0.1`。

### 3.5 监听范围约束

| 转发类型 | 默认监听地址 | 允许范围 | 约束 |
|----------|-------------|----------|------|
| 本地转发 | `127.0.0.1` | `127.0.0.1`、`::1`、`0.0.0.0` | `0.0.0.0` 需用户显式选择并提示安全风险 |
| 反向转发 | `127.0.0.1`（远端） | 由 `sshd_config GatewayPorts` 控制 | 客户端请求远端监听，实际范围由服务端策略决定 |
| 动态转发 | `127.0.0.1` | `127.0.0.1`、`::1` | 仅允许本地回环，MUST NOT 监听 `0.0.0.0` |

### 3.6 自动重连与端口转发

- 当端口转发的底层 SSH Transport 失效时，转发进入 `Failed` 状态。
- 独立长生命周期的转发支持自动重连（与终端标签使用相同退避策略）。
- 随标签页/随连接的转发不独立重连——由标签页的重连流程统一处理。

## 4. 平台约束

### 4.1 macOS

- 全部能力可用：工作区恢复、自动重连、三种端口转发。
- 后台监听：App 退出后端口转发停止（非系统服务）。
- 本地监听地址支持 IPv4 和 IPv6。

### 4.2 iPadOS

- 工作区恢复：可用（标签页结构持久化，App 重启后恢复）。
- 自动重连：可用（前台和短期后台切换时）。
- 端口转发：
  - 本地转发和动态转发在前台可用。
  - iPadOS 后台限制可能导致长时间后台时监听 Socket 被关闭。App 回到前台时检测并提示转发已失效，需用户手动重建。
  - 反向转发可用（依赖 SSH 连接存活）。
  - 不假设 iPadOS 有任意子进程或本地模型服务。

### 4.3 业务逻辑归属

所有重连策略、端口转发逻辑、状态管理均在 Rust 核心（`panda-core`）实现。Swift 侧仅通过 FFI 调用和 UI 展示，不使用 `#if os()` 引入业务逻辑分支。平台差异仅在 UI 提示和监听能力检测层面处理。

## 5. FFI 接口扩展（草案）

以下为新增 FFI 导出函数草案，具体签名在实施时确定：

```rust
// 自动重连配置
#[uniffi::export]
fn set_reconnect_policy(host_id: String, max_retries: u32, initial_backoff_secs: u32, max_backoff_secs: u32);

// 端口转发
#[uniffi::export]
fn port_forward_create(owner_id: String, kind: String, bind_address: String, bind_port: u16, remote_address: String, remote_port: u16) -> String;

#[uniffi::export]
fn port_forward_close(forward_id: String);

#[uniffi::export]
fn port_forward_list() -> Vec<PortForwardInfo>;

// 工作区状态
#[uniffi::export]
fn workspace_state_save();

#[uniffi::export]
fn workspace_state_restore() -> Vec<TabRestoreInfo>;
```

## 6. 修订清单

| 文件 | 修订内容 |
|------|----------|
| `openspec/specs/ssh-connection/spec.md` | 新增自动重连 Requirement |
| `openspec/specs/connection-pool/spec.md` | 新增重连期间所有权保持 Requirement |
| `openspec/specs/shell-terminal/spec.md` | 新增重连后 PTY 恢复 Requirement |
| `openspec/specs/workspace/spec.md` | 新增工作区状态持久化 Requirement |
| 新建 `openspec/specs/port-forwarding/spec.md` | 端口转发完整规格 |
| 新建 `openspec/specs/session-persistence/spec.md` | 会话持久化与恢复规格 |

## 7. 验收方法

- **TDD**：所有新能力先写失败测试，再写最小实现。
- **单元测试**：重连策略（退避计算、状态转换、安全约束）、端口转发（绑定/冲突/生命周期）、工作区状态（序列化/反序列化）。
- **集成测试**：使用 fake SSH server 模拟断线和重连。
- **手动测试**：macOS 和 iPadOS 真机验证端口转发和自动重连。
- **覆盖率**：满足 95% 行覆盖和区域覆盖门禁。
