# 任务：连接可靠性

## 前置条件

- [ ] `resolve-baseline-conflicts` 提案已完成，连接池残留复用条款已清理
- [ ] 路线图 Phase 0 基线关卡通过

## 任务清单

### 阶段一：会话持久化（T1-T4）

#### T1. 工作区状态数据模型与序列化（Rust 核心）

- [ ] 定义 `WorkspaceState` 结构体：标签页列表（主机 ID、类型、顺序、PTY 尺寸/SFTP 路径）
- [ ] 实现 `workspace_state_save()`：将当前工作区状态序列化为 `workspace-state.toml`
- [ ] 实现 `workspace_state_restore()`：读取并反序列化 `workspace-state.toml`
- [ ] 编写测试：正常序列化/反序列化、空状态、文件不存在、文件损坏、字段缺失
- **验收**：`cargo test` 通过，覆盖率达标

#### T2. 工作区状态 FFI 绑定

- [ ] 导出 `workspace_state_save` 和 `workspace_state_restore` FFI 函数
- [ ] 定义 `TabRestoreInfo` Record 类型
- [ ] 编写 FFI 层测试
- **验收**：`cargo test` 通过

#### T3. Swift 侧工作区恢复集成

- [ ] App 启动时调用 `workspace_state_restore()` 重建标签页结构
- [ ] 标签页关闭/新建时调用 `workspace_state_save()` 更新持久化状态
- [ ] 设置项 `restore_workspace_on_launch` 控制是否启用
- [ ] 编写 XCTest：恢复流程、设置关闭时不恢复
- **验收**：macOS 和 iPadOS 真机验证标签页恢复

#### T4. 工作区持久化 Spec 编写

- [ ] 新建 `openspec/specs/session-persistence/spec.md`
- [ ] 定义 Requirement：状态持久化、恢复时机、用户配置
- [ ] 定义 Scenario：正常恢复、空状态、文件损坏、设置关闭
- **验收**：规格评审通过

### 阶段二：自动重连（T5-T9）

#### T5. 重连策略核心逻辑（Rust）

- [ ] 定义 `ReconnectPolicy` 结构体（退避参数）
- [ ] 实现退避计算函数：`next_backoff(attempt, policy) -> Duration`
- [ ] 实现重连状态机：`Connected → Reconnecting → WaitBackoff → Reconnecting → ... → ReconnectFailed`
- [ ] 定义可重连错误类型（网络错误）和不可重连错误类型（认证失败、密钥不匹配）
- [ ] 编写测试：退避计算、状态转换、错误分类、最大重试、用户取消
- **验收**：`cargo test` 通过，覆盖率达标

#### T6. SSH 会话重连集成（Rust）

- [ ] 在 `SshSession` 层实现重连流程：检测失效 → 释放旧 Transport → 重新建连
- [ ] 重连时重新获取凭据（从凭据存储读取，不使用缓存）
- [ ] 重连时重新执行主机密钥检查
- [ ] 重连成功后重建 shell Channel 并恢复 PTY 尺寸
- [ ] 编写测试：使用 fake SSH server 模拟断线重连、凭据失效、密钥变更
- **验收**：`cargo test` 通过

#### T7. 重连 FFI 绑定与状态通知

- [ ] 导出 `set_reconnect_policy` FFI 函数
- [ ] 定义重连状态回调机制（重连中、重连成功、重连失败的事件通知）
- [ ] 编写 FFI 层测试
- **验收**：`cargo test` 通过

#### T8. Swift 侧重连 UI 集成

- [ ] 终端标签检测连接失效后自动触发重连流程
- [ ] 重连期间显示状态："正在重连... 第 N 次尝试，等待 Xs"
- [ ] 提供取消重连按钮
- [ ] 重连失败后显示手动重试入口
- [ ] 编写 XCTest：状态展示、取消流程
- **验收**：macOS 和 iPadOS 真机验证

#### T9. 自动重连 Spec 编写

- [ ] 修订 `openspec/specs/ssh-connection/spec.md`：新增「自动重连」Requirement
- [ ] 修订 `openspec/specs/connection-pool/spec.md`：新增重连期间所有权 Requirement
- [ ] 修订 `openspec/specs/shell-terminal/spec.md`：新增重连后 PTY 恢复 Requirement
- [ ] 定义 Scenario：正常重连、退避等待、达到上限、凭据失效、密钥变更、用户取消
- **验收**：规格评审通过

### 阶段三：端口转发（T10-T16）

#### T10. 端口转发数据模型与生命周期（Rust）

- [ ] 定义 `PortForwardConfig`、`ForwardKind`、`ForwardState` 结构体
- [ ] 实现端口转发注册表（按所有者管理转发条目）
- [ ] 实现生命周期管理：随标签页、随连接、独立长生命周期
- [ ] 编写测试：创建/关闭/列表、生命周期关联、所有者释放时转发关闭
- **验收**：`cargo test` 通过

#### T11. 本地端口转发实现（Rust）

- [ ] 实现本地 TCP 监听服务器
- [ ] 接受本地连接后通过 SSH `channel_open_direct_tcpip` 建立隧道
- [ ] 双向数据桥接（本地 Socket ↔ SSH Channel）
- [ ] 端口冲突检测：绑定前检查，返回 `PortConflict` 错误
- [ ] 编写测试：正常转发、端口冲突、连接关闭、数据传输
- **验收**：`cargo test` 通过

#### T12. 反向端口转发实现（Rust）

- [ ] 实现 SSH `tcpip-forward` 请求（远端监听）
- [ ] 远端有新连接时通过 SSH Channel 转发到本地
- [ ] 处理服务端拒绝（`sshd_config GatewayPorts` 策略）
- [ ] 编写测试：正常转发、服务端拒绝、连接关闭
- **验收**：`cargo test` 通过

#### T13. 动态端口转发实现（Rust）

- [ ] 实现本地 SOCKS5 代理服务器
- [ ] SOCKS5 CONNECT 请求解析后通过 SSH `channel_open_direct_tcpip` 建立隧道
- [ ] 支持 SOCKS5 认证（无认证模式）
- [ ] 仅允许绑定 `127.0.0.1` 和 `::1`，拒绝 `0.0.0.0`
- [ ] 编写测试：SOCKS5 握手、CONNECT 转发、非法绑定地址拒绝
- **验收**：`cargo test` 通过

#### T14. 端口转发 FFI 绑定

- [ ] 导出 `port_forward_create`、`port_forward_close`、`port_forward_list` FFI 函数
- [ ] 定义 `PortForwardInfo` Record 类型
- [ ] 编写 FFI 层测试
- **验收**：`cargo test` 通过

#### T15. Swift 侧端口转发 UI

- [ ] 端口转发管理面板（macOS 独立窗口/面板，iPadOS 工作区内页面）
- [ ] 创建转发对话框（类型选择、地址/端口输入、生命周期选择）
- [ ] 转发状态展示（活动/失败/已关闭）
- [ ] 端口冲突错误提示
- [ ] iPadOS 后台限制提示
- [ ] 编写 XCTest：创建/关闭流程、错误展示
- **验收**：macOS 和 iPadOS 真机验证

#### T16. 端口转发 Spec 编写

- [ ] 新建 `openspec/specs/port-forwarding/spec.md`
- [ ] 定义 Requirement：三种转发类型、生命周期、端口冲突、监听范围、平台约束
- [ ] 定义 Scenario：正常转发、端口冲突、所有者释放、iPadOS 后台限制、SOCKS5 非法绑定
- **验收**：规格评审通过

### 阶段四：集成与归档（T17-T19）

#### T17. 远端进程恢复命令（可选）

- [ ] 在 `HostConfig` 中新增 `session_restore_command: Option<String>` 字段
- [ ] 重连成功后自动执行恢复命令（等同于用户输入）
- [ ] 编写测试：有恢复命令时执行、无命令时跳过、命令执行失败不影响连接
- **验收**：`cargo test` 通过

#### T18. 端到端集成测试

- [ ] 自动重连 + 端口转发：Transport 失效后独立转发状态正确
- [ ] 工作区恢复 + 自动重连：App 重启后标签页恢复并自动重连
- [ ] 多标签页场景：一个标签重连不影响其他标签
- [ ] 编写集成测试
- **验收**：全部测试通过

#### T19. 评审与归档

- [ ] 提交 PR，附设计说明
- [ ] 评审通过后合并
- [ ] 将 spec-deltas 合并回 `openspec/specs/`
- [ ] 归档变更提案
- [ ] 路线图 1.4 相关缺口标记为已处理

## 依赖关系

```
T1 ──→ T2 ──→ T3 ──→ T4
                    │
T5 ──→ T6 ──→ T7 ──→ T8 ──→ T9
                              │
T10 ──→ T11 ──┐               │
T10 ──→ T12 ──┼──→ T14 ──→ T15 ──→ T16
T10 ──→ T13 ──┘                    │
                                   │
T17（可选，与 T9/T16 并行）        │
                                   │
T4 + T9 + T16 ──→ T18 ──→ T19
```

- T1-T4（会话持久化）可独立推进
- T5-T9（自动重连）可独立推进
- T10-T16（端口转发）可独立推进
- T17 可选，与 T9/T16 并行
- T18 依赖全部 spec 编写完成
- T19 依赖 T18

三个阶段可并行开发（不同开发者或交替推进），T18 需要全部完成后做集成验证。

## 预估工作量

| 阶段 | 任务 | 预估 |
|------|------|------|
| 会话持久化 | T1-T4 | 3 天 |
| 自动重连 | T5-T9 | 4 天 |
| 端口转发 | T10-T16 | 5 天 |
| 集成与归档 | T17-T19 | 2 天 |
| **总计** | | **约 14 天** |

## 风险

- 自动重连需处理凭据过期和主机密钥变更，安全约束复杂度高
- iPadOS 后台限制对端口转发的实际可用性影响需真机验证
- 端口转发涉及 TCP 代理和 SOCKS5 协议，实现复杂度中等
- russh 对 `tcpip-forward`（反向转发）的支持需验证
