# 设计：SSH 跳板机（Proxy Jump）

## 1. 数据模型变更

### 1.1 HostConfig 新增字段

在 `HostConfig` 中新增可选字段 `proxy_jump`：

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostConfig {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
    pub notes: Option<String>,
    pub group_id: Option<String>,
    /// 跳板机引用：指向另一台 `HostConfig` 的 id。
    /// 连接时先建立跳板机 SSH 会话，再通过 direct-tcpip 通道承载目标连接。
    /// 支持递归引用（多级跳板），但 MUST 无环且不超过最大链深。
    pub proxy_jump: Option<String>,
}
```

TOML 示例：

```toml
[[hosts]]
id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
name = "内网服务器"
host = "10.0.0.5"
port = 22
username = "deploy"
auth = { type = "PublicKey", key_path = "~/.ssh/id_ed25519", passphrase_ref = "key-pass-1" }
proxy_jump = "11111111-2222-3333-4444-555555555555"

[[hosts]]
id = "11111111-2222-3333-4444-555555555555"
name = "跳板机"
host = "bastion.example.com"
port = 22
username = "admin"
auth = { type = "Password", password_ref = "bastion-pass" }
```

旧版配置缺少 `proxy_jump` 字段时 MUST 按 `None`（直连）处理，无需迁移。

### 1.2 配置校验约束

配置层在 upsert 和加载时 MUST 执行以下校验：

| 约束 | 违反时行为 |
|------|-----------|
| `proxy_jump` 引用的 id 必须存在于同一配置存储 | 拒绝 upsert，返回 `DanglingProxyJumpRef` 错误 |
| `proxy_jump` 不得指向自身 id | 拒绝 upsert，返回 `SelfReferencingProxyJump` 错误 |
| 跳板链不得成环 | 拒绝 upsert，返回 `CyclicProxyJump` 错误 |
| 跳板链深度不得超过 `MAX_PROXY_CHAIN_DEPTH`（8） | 拒绝 upsert，返回 `ProxyJumpChainTooDeep` 错误 |

校验函数 `validate_proxy_jump_chain` 从目标主机出发，沿 `proxy_jump` 递归遍历，使用 `HashSet` 检测环，计数检测深度。

### 1.3 删除约束（RESTRICT）

删除 `HostConfig` 时，若该 id 被其他主机的 `proxy_jump` 引用：

- MUST 拒绝删除，返回 `ProxyJumpInUse` 错误
- 错误信息 MUST 包含引用方的 id 和 name 列表
- 调用方须先修改或删除引用方，再删除被引用方

此约束在 `ConfigStore::delete` 层统一实施，覆盖 UI、导入和 MCP 入口。

## 2. 连接流程

### 2.1 跳板链解析

连接目标主机前，先解析完整跳板链：

```
resolve_proxy_chain(target_cfg, config_store) -> Vec<HostConfig>
```

从目标主机开始，沿 `proxy_jump` 反向收集，结果为 `[跳板1, 跳板2, ..., 目标]`。解析过程中再次执行环检测和深度检查（防御性校验，配置层已保证）。

### 2.2 逐跳连接

连接流程为递归结构：

```
connect_via_proxy(chain, credentials_map, known_hosts, policies) -> SshSession
```

1. **建立跳板1 的 SSH 连接**：
   - 以 `TcpStream` 连接跳板1 的 `(host, port)`
   - 执行主机密钥校验（复用 `ClientHandler` + `KnownHosts`）
   - 使用跳板1 的凭据认证

2. **建立跳板2 的 SSH 连接**（通过跳板1 中转）：
   - 在跳板1 的 SSH 会话上打开 `direct-tcpip` 通道，目标为跳板2 的 `(host, port)`
   - 将 `direct-tcpip` 通道包装为 `AsyncRead + AsyncWrite` 流
   - 以此流替代 `TcpStream`，执行 SSH 握手
   - 执行主机密钥校验（注意：此时校验的是跳板2 的密钥，host/port 使用跳板2 的配置值）
   - 使用跳板2 的凭据认证

3. **递归直到目标主机**：
   - 最后一级通过倒数第二级跳板的 `direct-tcpip` 通道连接目标
   - 目标主机的 SSH 握手、密钥校验和认证与前相同

### 2.3 流抽象

当前 `CountingStream` 底层为 `TcpStream`。跳板连接需要将 `direct-tcpip` 通道也包装为 `AsyncRead + AsyncWrite`。

设计 `ProxyJumpStream`：

```rust
/// 承载跳板连接的流：底层可以是 TcpStream 或 direct-tcpip Channel。
enum TransportStream {
    Tcp(tokio::net::TcpStream),
    DirectTcpip(DirectTcpipChannel),
}
```

`DirectTcpipChannel` 包装 russh 的 `Channel<client::Msg>`，实现 `AsyncRead`/`AsyncWrite`：
- `poll_read`：从 Channel 读取 `ChannelMsg::Data`
- `poll_write`：向 Channel 发送数据
- `poll_flush`/`poll_shutdown`：关闭 Channel

`CountingStream` 的 `inner` 字段从 `TcpStream` 改为 `TransportStream`，保持 I/O 计量逻辑不变。

### 2.4 主机密钥校验

每跳的主机密钥校验独立进行：

- 跳板1：以跳板1 的 `(host, port)` 校验
- 跳板2：以跳板2 的 `(host, port)` 校验（即使物理连接经过跳板1）
- 目标：以目标的 `(host, port)` 校验

密钥校验使用各自的 `KnownHosts` 实例（共享同一 known_hosts 文件路径），策略由调用方统一传入。

**关键约束**：`direct-tcpip` 通道承载的是加密隧道，目标 SSH 握手发生在隧道内部，服务端呈现的密钥是目标主机的密钥，不是跳板机的。known_hosts 中的 host key 记录按各跳自身的 `(host, port)` 存储和校验。

### 2.5 凭据获取

每跳使用各自 `HostConfig` 的 `auth` 配置获取凭据：

- 跳板1 使用跳板1 的 `password_ref` 或 `key_path + passphrase_ref`
- 跳板2 使用跳板2 的凭据
- 目标使用目标的凭据

凭据由调用方（FFI 层或上层 AppModel）在连接前按链中各主机的 `auth` 配置从凭据文件取出，以 `Vec<Credentials>` 传入连接函数。凭据不经过 FFI 落盘，不在连接函数内部访问凭据文件。

### 2.6 超时策略

| 超时项 | 默认值 | 说明 |
|--------|--------|------|
| 每跳 TCP/通道连接超时 | 30 秒 | 与现有 `DEFAULT_TIMEOUT` 一致 |
| 每跳 SSH 握手超时 | 30 秒 | 与现有 `DEFAULT_TIMEOUT` 一致 |
| 每跳认证超时 | 30 秒 | 与现有 `DEFAULT_TIMEOUT` 一致 |
| 整链连接超时 | 无独立超时 | 各跳超时之和自然构成上限 |

不引入独立的整链超时：每跳已有独立超时，整链超时为各跳超时之和（最坏情况 `chain_depth * 90s`）。若后续需要更精细控制，可在提案中追加。

### 2.7 失败清理

连接链中任一跳失败时，必须关闭已建立的所有中间连接：

```rust
async fn connect_chain(
    chain: &[HostConfig],
    credentials: Vec<Credentials>,
    known_hosts: &mut KnownHosts,
    policies: &[UnknownHostKeyPolicy],
) -> Result<SshSession> {
    let mut intermediate_sessions = Vec::new();

    for (i, hop_cfg) in chain.iter().enumerate() {
        let result = if i == 0 {
            // 第一跳：TCP 直连
            SshSession::connect(hop_cfg, credentials[i].clone(), known_hosts, policies[i]).await
        } else {
            // 后续跳：通过前一跳的 direct-tcpip 通道
            let prev = intermediate_sessions.last().unwrap();
            connect_via_direct_tcpip(
                prev, hop_cfg, credentials[i].clone(), known_hosts, policies[i]
            ).await
        };

        match result {
            Ok(session) => intermediate_sessions.push(session),
            Err(error) => {
                // 清理所有已建立的中间连接
                for session in intermediate_sessions.into_iter().rev() {
                    let _ = session.disconnect().await;
                }
                return Err(error);
            }
        }
    }

    // 最后一个是目标会话，前面的都是中间跳板
    // 中间跳板的 SshSession 必须保持存活（它们承载 direct-tcpip 通道）
    // 目标 SshSession 返回给调用方
    // 中间会话的生命周期绑定到目标会话
    Ok(intermediate_sessions.into_iter().last().unwrap())
}
```

**生命周期绑定**：中间跳板的 `SshSession` 必须与目标会话保持相同的生命周期。目标会话关闭时，中间会话自动释放（`direct-tcpip` 通道关闭后，底层 SSH 连接不再被使用）。

设计选择：将中间会话的 `Handle` 存储在返回的 `SshSession` 中，作为 `_proxy_chain: Vec<SshSession>` 字段。Drop 时按反序关闭。

## 3. 错误处理

### 3.1 新增错误类型

```rust
// Error enum 新增变体
pub enum Error {
    // ... 现有变体 ...

    /// 跳板机引用不存在
    DanglingProxyJumpRef { proxy_id: String },
    /// 跳板机自引用
    SelfReferencingProxyJump { host_id: String },
    /// 跳板链成环
    CyclicProxyJump { chain: Vec<String> },
    /// 跳板链超过最大深度
    ProxyJumpChainTooDeep { depth: usize, max: usize },
    /// 跳板机被引用，无法删除
    ProxyJumpInUse { referenced_by: Vec<(String, String)> },
    /// 跳板链中某跳连接失败
    ProxyJumpFailed { hop_index: usize, hop_host: String, source: Box<Error> },
}
```

### 3.2 错误传播

跳板链中第 N 跳失败时：
- 返回 `ProxyJumpFailed { hop_index, hop_host, source }`，`source` 为该跳的实际错误（超时、认证失败、密钥不匹配等）
- 已建立的中间连接全部关闭
- 调用方可根据 `hop_index` 和 `source` 向用户展示精确的失败位置

## 4. 配置导入导出

### 4.1 ID 重映射

导出时：`proxy_jump` 字段保存的是内部 id，导出格式不变。

导入时：若导入的主机 id 与已有主机冲突需要重新生成，则所有引用该 id 的 `proxy_jump` 字段也 MUST 同步更新为新 id。

### 4.2 悬空引用处理

导入时若 `proxy_jump` 引用的 id 在目标存储中不存在：
- MUST NOT 静默丢弃引用（改为直连）
- MUST 报错并列出悬空引用
- 用户可选择：跳过该主机导入，或先导入被引用的跳板机

## 5. 安全约束

### 5.1 凭据隔离

- 每跳凭据独立获取，不在跳板间共享
- 凭据不经过 FFI 落盘，由调用方从凭据文件取出后传入
- 跳板机的凭据仅用于跳板机认证，不暴露给目标主机

### 5.2 主机密钥

- 每跳独立校验主机密钥，不跳过任何一跳的校验
- 跳板机的 known_hosts 记录按跳板机自身的 `(host, port)` 存储
- 目标主机的 known_hosts 记录按目标自身的 `(host, port)` 存储
- 密钥变更（Mismatch）在任何一跳都阻断连接

### 5.3 审计

- 连接时记录完整跳板链路径（各跳的 id、host、port）
- 跳板链变化使已审核的执行计划授权失效（与审计/授权提案联动）
- 遥测记录目标主机的连接，附带跳板链元数据

### 5.4 约束汇总

| 约束 | 实施层 | 说明 |
|------|--------|------|
| 环/深度/悬空检测 | Rust 配置层 | upsert 和加载时强制校验 |
| 删除 RESTRICT | Rust 配置层 | 统一检查，覆盖所有入口 |
| 每跳密钥校验 | Rust SSH 层 | 复用现有 KnownHosts 体系 |
| 每跳认证 | Rust SSH 层 | 复用现有 Credentials 体系 |
| 凭据不落盘 | FFI 层 | 与现有安全红线一致 |
| 跳板链审计 | Rust 层 | 记录完整路径 |

## 6. FFI 绑定

### 6.1 新增/修改导出

```rust
// HostConfig 的 proxy_jump 字段通过 uniffi Record 自动导出

// 新增错误类型通过 uniffi Enum 自动导出

// 连接函数签名不变：proxy_jump 是 HostConfig 的一部分
// test_connection / sftp_connect 等入口不需要修改签名
// 内部自动处理跳板链
```

### 6.2 逐跳指纹确认

连接入口（`test_connection`）的现有流程需要扩展：

1. 解析跳板链
2. 逐跳以 `Reject` 策略探测
3. 若某跳返回 `UnknownHostKey`，暂停链建立，将该跳的指纹信息返回 UI
4. UI 展示跳板信息（名称、位置）和指纹，用户确认
5. 用户确认后存储该跳密钥，继续链建立
6. 若后续跳也遇到 Unknown，重复步骤 3-5

FFI 需要新增返回类型，携带跳板链中的位置信息：

```rust
pub struct ProxyJumpUnknownHostKey {
    pub hop_index: usize,
    pub hop_host_config: HostConfig,
    pub presented: String,
    pub fingerprint: String,
}
```

## 7. 对现有功能的影响

### 7.1 向后兼容

- `proxy_jump` 为 `Option<String>`，旧配置无此字段时按 `None` 处理
- 现有连接流程不变：`proxy_jump == None` 时走原有 `TcpStream` 直连
- FFI 签名不变：跳板链处理对调用方透明

### 7.2 性能

- 配置校验（环/深度检测）：O(chain_depth)，链深不超过 8，开销可忽略
- 连接延迟：每增加一跳增加一次 SSH 握手 + 一次 direct-tcpip 通道建立的延迟
- 内存：每跳持有一个 `SshSession`，与跳数成正比

### 7.3 连接所有权

- 跳板连接的目标会话由调用方独占，与现有连接所有权模型一致
- 中间跳板会话的生命周期绑定到目标会话，不跨所有者共享
