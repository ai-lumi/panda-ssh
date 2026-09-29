# 设计：SSH 端口转发（Port Forwarding）

## 1. 整体架构

```
┌──────────────────────────────────────────────────────────┐
│                   Panda Core (Rust)                      │
│                                                          │
│  ┌─────────────────┐    ┌──────────────────────────┐     │
│  │ ForwardManager   │───▶│ LocalForwardService       │     │
│  │ (所有权/生命周期) │    │  ├─ TcpListener          │     │
│  │                  │    │  └─ direct-tcpip bridge    │     │
│  │                  │    ├──────────────────────────┤     │
│  │                  │───▶│ RemoteForwardService      │     │
│  │                  │    │  ├─ tcpip-forward req     │     │
│  │                  │    │  └─ remote→local bridge   │     │
│  │                  │    ├──────────────────────────┤     │
│  │                  │───▶│ DynamicForwardService     │     │
│  │                  │    │  ├─ SOCKS5 server         │     │
│  │                  │    │  └─ per-request direct-tcp│     │
│  └─────────────────┘    └──────────────────────────┘     │
│         │                           │                    │
│         ▼                           ▼                    │
│  ┌──────────────────────────────────────────────┐       │
│  │ SSH Transport (russh client Session)          │       │
│  │  ├─ channel_open_direct_tcpip()              │       │
│  │  └─ tcpip_forward() request                   │       │
│  └──────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────┘
         ▲                              ▲
         │ FFI (uniffi)                 │ FFI
         ▼                              ▼
   ┌──────────┐                   ┌──────────┐
   │ SwiftUI   │                   │  FFI      │
   │ 管理面板   │                   │ (panda-   │
   └──────────┘                   │  ffi)     │
                                   └──────────┘
```

## 2. 数据模型

### 2.1 统一转发配置

三种转发共用一个配置结构：

```rust
/// 转发类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardKind {
    /// 本地转发：本地监听 → direct-tcpip → 远端
    Local,
    /// 反向转发：tcpip-forward → 远端回连 → 本地
    Remote,
    /// 动态转发：SOCKS5 代理 → 每请求 direct-tcpip
    Dynamic,
}

/// 转发生命周期
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardLifecycle {
    /// 随标签页：转发随创建它的 SSH 标签页关闭而关闭
    WithTab,
    /// 随连接：转发随其独占的 SSH Transport 释放而关闭
    WithConnection,
    /// 独立长生命周期：转发拥有自己的 SSH Transport，持久化存储
    Independent,
}

/// 端口转发配置（TOML 序列化）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForwardConfig {
    /// 唯一 ID
    pub id: String,
    /// 转发类型
    pub kind: ForwardKind,
    /// 所有者 ID（标签页 ID 或独立 UUID）
    pub owner_id: String,
    /// 所有者类型
    pub owner_type: OwnerType,
    /// 生命周期
    pub lifecycle: ForwardLifecycle,
    /// 绑定的 SSH 主机 ID（从哪台主机建立转发）
    pub host_id: String,
    /// 本地监听地址（Local/Dynamic 使用）
    pub local_addr: String,
    /// 本地监听端口
    pub local_port: u16,
    /// 远端目标地址（Local 使用）或本地回连地址（Remote 使用）
    pub target_addr: String,
    /// 远端目标端口
    pub target_port: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerType {
    Tab,
    Independent,
}
```

TOML 持久化（仅 `Independent` 生命周期需要）：

```toml
# port_forwarding.toml（与 hosts.toml 同目录）
[[forwards]]
id = "aaaa-bbbb-cccc-dddd"
kind = "Local"
owner_id = "aaaa-bbbb-cccc-dddd"
owner_type = "Independent"
lifecycle = "Independent"
host_id = "1111-2222-3333-4444"
local_addr = "127.0.0.1"
local_port = 8080
target_addr = "localhost"
target_port = 80
```

### 2.2 运行时状态

```rust
/// 转发运行时状态
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardStatus {
    /// 监听中 / 等待远端回连
    Listening,
    /// 活动中（有活跃数据流）
    Active,
    /// 已暂停
    Paused,
    /// 已停止
    Stopped,
    /// 错误状态
    Error(String),
}

/// 转发运行时信息（FFI 返回）
#[derive(Debug, Clone)]
pub struct ForwardRuntimeInfo {
    pub id: String,
    pub kind: ForwardKind,
    pub owner_id: String,
    pub host_id: String,
    pub status: ForwardStatus,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub start_time: Option<DateTime<Utc>>,
}
```

## 3. 核心服务模块

### 3.1 ForwardManager（统一入口）

```rust
pub struct ForwardManager {
    /// 活跃转发表：forward_id → ForwardRuntime
    forwards: RwLock<HashMap<String, ForwardRuntime>>,
    /// 独立转发持久化存储
    store: ForwardStore,
}
```

公共接口：

| 方法 | 说明 |
|------|------|
| `create(config, transport)` | 创建并启动转发，返回 `forward_id` |
| `close(forward_id)` | 关闭指定转发 |
| `close_by_owner(owner_id)` | 关闭指定所有者的全部转发（标签页关闭时调用） |
| `close_by_transport(transport_id)` | 关闭绑定到指定 SSH Transport 的全部转发（连接释放时调用） |
| `list() / get(forward_id)` | 查询转发列表 / 单个转发状态 |
| `start_independent_forwards()` | App 启动时恢复 Independent 转发（从持久化存储） |

### 3.2 LocalForwardService（本地转发）

核心循环：

```rust
async fn run(config: ForwardConfig, transport: &SshTransport) {
    // 1. 绑定本地监听端口
    let listener = TcpListener::bind(config.bind_addr_port()).await
        .map_err(|e| map_bind_error(e, config.local_port))?;

    // 2. 循环 accept
    loop {
        let (local_stream, _) = listener.accept().await;

        // 3. 在 SSH Transport 上打开 direct-tcpip 到远端目标
        let mut channel = transport
            .open_direct_tcpip(&config.target_addr, config.target_port)
            .await?;

        // 4. 双向数据流桥接
        //    local_stream ↔ channel
        tokio::io::copy_bidirectional(
            &mut CountingReader(local_stream),
            &mut channel,  // 需实现 AsyncRead + AsyncWrite
        ).await;

        // 5. 任一端关闭后，清理资源，继续 accept 循环
    }
}
```

**DirectTcpipChannel 实现**：包装 russh 的 `Channel<client::Msg>`，实现 `AsyncRead` + `AsyncWrite`：

```rust
pub struct DirectTcpipChannel {
    channel: Channel<client::Msg>,
}

impl AsyncRead for DirectTcpipChannel {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        // 从 russh Channel 读取 ChannelMsg::Data，写入 buf
        // ChannelMsg::Eof / ChannelMsg::Close 时返回 Ok(()) 表示流结束
    }
}

impl AsyncWrite for DirectTcpipChannel {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        // 向 russh Channel 发送 ChannelMsg::Data(buf.to_vec())
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))  // russh channel 无显式 flush
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // 发送 ChannelMsg::Close，等待确认
    }
}
```

### 3.3 RemoteForwardService（反向转发）

```rust
async fn run(config: ForwardConfig, transport: &SshTransport) {
    // 1. 向 SSH 服务端请求 tcpip-forward
    //    参数：远端 bind address + port
    let mut forwarder = transport.request_tcpip_forward(
        &config.remote_bind_addr,
        config.remote_bind_port,
    ).await.map_err(|e| map_forward_error(e))?;

    // 2. 等待服务端回调（远端连接到达）
    //    russh 的 tcpip-forward 会返回一个 stream，产出 Accept 事件
    loop {
        let (channel, origin_addr) = forwarder.accept().await?;

        // 3. 在本地连接目标
        let mut local_stream = TcpStream::connect(&config.target_addr_port()).await?;

        // 4. 双向桥接
        //    channel ↔ local_stream
        tokio::io::copy_bidirectional(
            &mut DirectTcpipChannel::from(channel),
            &mut CountingReader(local_stream),
        ).await;
    }
}
```

### 3.4 DynamicForwardService（SOCKS5）

```rust
async fn run(config: ForwardConfig, transport: &SshTransport) {
    // 1. 绑定本地 SOCKS5 端口
    let listener = TcpListener::bind(&config.bind_addr_port()).await?;

    // 2. 循环 accept
    loop {
        let local_stream = listener.accept().await?.0;

        // 3. 在单独 task 中处理 SOCKS5 握手
        tokio::spawn(handle_socks5(local_stream, transport.clone()));
    }
}

async fn handle_socks5(mut local: TcpStream, transport: SshTransport) {
    // SOCKS5 握手：
    // 1. 读取客户端认证方法列表 → 响应 "无认证方法"
    // 2. 读取 CONNECT 请求（地址可以是 IPv4 / IPv6 / 域名）
    // 3. 在 SSH Transport 上打开 direct-tcpip 到目标地址
    // 4. 响应成功
    // 5. 双向桥接：local ↔ direct-tcpip channel
}
```

SOCKS5 初期只支持：
- CONNECT 命令（不支持 BIND / UDP ASSOCIATE）
- 目标地址类型：IPv4 + 域名（不支持 IPv6，后续追加）
- 无认证（不支持 SOCKS5 用户名密码认证，后续追加）

## 4. 所有权与生命周期

### 4.1 所有权约束

| 约束 | 实施位置 |
|------|---------|
| 每条转发关联一个 `owner_id` | `ForwardConfig.owner_id` 必填字段 |
| 同一 `owner_id` 的转发独占其 SSH Transport | `ForwardManager` 创建转发时验证 Transport 所有权 |
| 跨所有者不共享 Transport | Transport 在创建转发时按 owner_id 分配，不允许另一个 owner 使用 |

**Transport 所有权**：每条转发持有自己的 SSH Transport handle。同一 owner 的多条转发可以共享同一 Transport（连接池复用），但不同 owner 之间不共享。

### 4.2 生命周期钩子

| 生命周期 | 创建 | 关闭触发 |
|----------|------|---------|
| WithTab | 标签页创建转发时 | 标签页关闭 → `ForwardManager.close_by_owner(tab_id)` |
| WithConnection | SSH 连接已建立时（在 Transport 上创建） | SSH Transport 释放 → `ForwardManager.close_by_transport(transport_id)` |
| Independent | 用户显式创建，`ForwardManager` 建立独立 SSH Transport | 用户手动关闭 / App 退出时持久化，下次启动自动恢复 |

## 5. 错误类型

```rust
/// 转发相关错误
#[derive(Debug, Error)]
pub enum ForwardError {
    /// 本地端口被占用
    #[error("端口 {port} 已被占用")]
    PortConflict { port: u16 },
    /// 绑定非回环地址被拒绝
    #[error("动态转发不允许绑定 0.0.0.0")]
    BindNonLoopbackDenied,
    /// 服务端拒绝 tcpip-forward 请求
    #[error("服务端拒绝端口转发请求：{reason}")]
    ServerForwardDenied { reason: String },
    /// 所有者未找到
    #[error("所有者不存在：{owner_id}")]
    OwnerNotFound { owner_id: String },
    /// 转发未找到
    #[error("转发不存在：{forward_id}")]
    ForwardNotFound { forward_id: String },
    /// 所有者已有关联转发，不允许独立 Transport
    #[error("所有者 {owner_id} 已持有转发，Transport 独占违反")]
    TransportAlreadyOwned { owner_id: String },
    /// SOCKS5 协议错误
    #[error("SOCKS5 协议错误：{reason}")]
    Socks5Error { reason: String },
    /// 底层 I/O 或 SSH 错误
    #[error("底层错误：{0}")]
    IoOrSsh(#[from] Box<dyn std::error::Error + Send>),
}
```

## 6. FFI 接口

```rust
// uniffi 导出
pub fn forward_create(config: ForwardConfig, host_id: String) -> Result<String, ForwardError>;
pub fn forward_close(forward_id: String) -> Result<(), ForwardError>;
pub fn forward_list() -> Vec<ForwardRuntimeInfo>;
pub fn forward_get(forward_id: String) -> Option<ForwardRuntimeInfo>;
pub fn forwards_close_by_owner(owner_id: String) -> Result<(), ForwardError>;

// 内部使用（不导出）
pub(crate) fn forward_start_independent_forwards() -> Result<(), ForwardError>;
```

**FFI 约束**：
- FFI 层只负责 `ForwardConfig` DTO → 核心调用的桥接
- Transport 管理在 Rust 核心完成（根据 `host_id` 从会话池取 Transport）
- 失败清理、端口冲突检测、所有权验证全部在 Rust 核心

## 7. 平台约束

| 平台 | 行为 |
|------|------|
| **macOS** | 无特殊限制。App 退出后转发停止（非系统服务）。 |
| **iPadOS** | 后台长时间驻留时，系统可能关闭 socket。前台恢复时检测：尝试重新 bind 本地监听；如果 bind 成功且 Transport 仍存活，重启转发；如果失败则提示用户重建。 |
| **Linux** | 同 macOS（后续实现，当前重点 macOS/iPadOS） |

iPadOS 恢复检测实现：`AppDidBecomeActive` → FFI 调用 `forward_resume_check()` → Rust 核心遍历所有活动转发，尝试重新 bind 并检查 Transport 健康状态。

## 8. 对现有功能的影响

### 8.1 向后兼容

- 全部新增模块，不修改现有 SSH/SFTP/传输代码
- `SshSession` / Transport 接口新增但签名不变
- 独立转发持久化文件 `port_forwarding.toml` 自动创建，缺失时按空集合处理

### 8.2 与 add-ssh-proxy-jump 的关系

- 共享 `DirectTcpipChannel` 流包装实现（如果 proxy-jump 先做，Port Forwarding 直接复用）
- TransportStream 枚举（如果 proxy-jump 引入了）可以作为 Port Forwarding 的底层抽象
- **建议先做 proxy-jump**，让 DirectTcpipChannel 的实现被充分测试后 Port Forwarding 复用

### 8.3 停机清理

- 新增独立转发需要纳入 `WorkspaceService` 的停机链条：App 退出时关闭所有活动转发（除了 Independent 转发需要持久化恢复）
- 标签页关闭时已有关闭确认流程不变，但新增"该标签页关联了 N 条端口转发"的提示（Phase 3 追加，Phase 1 先只做静默清理）
