# SSH 端口转发（Port Forwarding）

> 状态：草案 | 创建日期：2026-09-29 | 关联路线图：v1.1.0 规划

## 问题

当前应用支持 SSH 终端和 SFTP 文件传输，但用户无法在应用内创建 SSH 端口转发隧道。常见场景：

- **本地转发**（`ssh -L`）：在本地监听一个端口，将流量通过 SSH 隧道转发到远端内网服务（如数据库、Web 管理界面）
- **反向转发**（`ssh -R`）：让远端服务器回连到本地服务（如在 NAT 后的本地开发环境暴露给外部测试）
- **动态转发**（`ssh -D`）：启动 SOCKS5 代理，将所有指定端口的流量通过隧道转发

现有代码中 `SshSession` 以 `TcpStream` 直连，未实现 SSH `direct-tcpip` 通道和 `tcpip-forward` 请求。基础依赖已就绪（russh 0.62 支持这些功能，需 spike 验证具体 API）。

## 目标

1. 支持本地端口转发（`ssh -L` 等效）：本地监听 → `direct-tcpip` → 远端目标
2. 支持反向端口转发（`ssh -R` 等效）：`tcpip-forward` 请求 → 远端回连 → 本地目标
3. 支持动态端口转发（`ssh -D` 等效）：本地 SOCKS5 → `direct-tcpip` → 用户指定目标
4. 所有权模型：转发关联所有者（标签页 / 独立任务），按所有者独占 Transport
5. 生命周期模型：三种模式（随标签页 / 随连接 / 独立长生命周期）
6. 端口冲突处理：不静默换端口，显式返回 `PortConflict` 错误

## 范围

### 包含

- **Phase 1 — 本地转发**：`ssh -L` 等效能力，本地 TCP listener + `direct-tcpip` 桥接
- **Phase 2 — 反向转发**：`ssh -R` 等效能力，`tcpip-forward` 请求 + 远端回连处理
- **Phase 3 — SOCKS5 动态转发**：`ssh -D` 等效能力 + 完整所有权/生命周期管理

Phase 1 优先开发，Phase 2、3 在其基础上迭代。每阶段独立可交付。

### 不包含

- HTTP 代理（独立类型）
- SSH Agent 转发
- X11 转发
- VPN 级别的系统全局代理集成
- 端口转发经跳板机（依赖 add-ssh-proxy-jump 完成后可追加）

## 依赖前置

| Spike | 内容 | 状态 |
|-------|------|------|
| R1 | russh 0.62 `channel_open_direct_tcpip` API 验证 + Channel 包装为 AsyncRead/AsyncWrite | 待验证 |
| R2 | russh 0.62 `tcpip-forward` 请求 + 回调机制验证 | 待验证 |
| R3 | 本地 TCP listener ↔ `direct-tcpip` 数据流桥接 PoC | 待验证 |

三个 spike 全绿才能进入正式开发。如果任何一个失败（API 签名不对或版本不支持），需升级 russh 或调整实现方案。

## 验收标准

### 通用（全部阶段）

- [ ] `cargo test` 全绿，覆盖率 ≥ 95%
- [ ] 正常 / 意外 / 边界三类测试场景完整覆盖
- [ ] 平台条件编译合规（业务逻辑只在 Rust 核心，Swift 侧仅经 FFI 调用）

### Phase 1 — 本地转发

- [ ] 本地 `127.0.0.1:8080` → 远端 `localhost:80` 端到端可用
- [ ] 端口被占用返回 `PortConflict`，不静默换端口
- [ ] 随标签页生命周期：关闭标签页时转发自动关闭
- [ ] 随连接生命周期：SSH Transport 释放时转发自动关闭
- [ ] FFI 提供 `local_forward_create` / `local_forward_list` / `local_forward_close`
- [ ] SwiftUI 管理面板展示活动转发列表

### Phase 2 — 反向转发

- [ ] 远端 `127.0.0.1:9090` → 本地 `localhost:3000` 端到端可用
- [ ] 服务端拒绝 `tcpip-forward` 时返回明确错误
- [ ] FFI 提供 `remote_forward_create` / `remote_forward_list` / `remote_forward_close`

### Phase 3 — SOCKS5 + 完整生命周期

- [ ] 本地 SOCKS5 代理可用，SOCKS CONNECT 请求正确解析并转发
- [ ] 动态转发 MUST NOT 绑定 `0.0.0.0`
- [ ] 独立长生命周期转发持久化（`port_forwarding.toml`），App 重启后恢复
- [ ] 按所有者独占 Transport：多所有者并发转发不互相干扰

## 风险

| 风险 | 等级 | 缓解 |
|------|------|------|
| russh 0.62 不支持所需 API 或签名不对 | 中 | Phase 0 Spike R1-R3 前置验证 |
| `tokio::io::copy_bidirectional` 在 SSH channel 上的行为 | 低 | 用 mock Channel 先写单测，再集成验证 |
| SOCKS5 协议实现的边界条件（认证请求、UDP 关联、多种地址类型） | 中 | 初期只支持 SOCKS5 CONNECT + IPv4/域名，UDP 和 BIND 后续追加 |
| iPadOS 后台限制导致 listener socket 被系统关闭 | 中 | 按 spec 要求：前台恢复时检测状态并提示重建 |
| 数据流双向拷贝的背压和清理 | 中 | 超时 + 取消 + 资源计数测试覆盖 |

## 预估工作量

| 阶段 | 预估 |
|------|------|
| Phase 0 — Spike R1-R3 | 1-2h |
| Phase 1 — 本地转发 | 10h |
| Phase 2 — 反向转发 | 6h |
| Phase 3 — SOCKS5 + 完整生命周期 | 8h |
| 评审 + 覆盖率补齐 | 3h |
| **总计** | **约 28-30h** |

## 后续工作

- 端口转发经跳板机：依赖 add-ssh-proxy-jump 完成，在其 TransportStream 基础上扩展
- 转发流量统计和可视化：在管理面板展示实时字节数和速率
- SSH Agent 转发 / X11 转发：独立提案
