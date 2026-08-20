# Spec Delta: connection-pool

## Removed Requirements

### Requirement: 空闲超时回收

~~系统 SHALL 对池内连接维护空闲超时机制（默认 30 秒）。会话自上一次被使用后超过空闲超时时间未被再次使用，系统 SHALL 自动断开并移出连接池。~~

**Reason:** 桌面 SSH 客户端的连接生命周期应由 UI 标签页驱动，而非时间超时。空闲超时导致用户切换 tab 后连接被回收，体验差。

## Modified Requirements

### Requirement: 连接复用

系统 SHALL 维护一个以 `(host_id, credentials)` 为键的连接缓存。对同一主机的后续操作优先复用缓存中已有的可用 `SshSession`，SHALL NOT 在无可用会话时直接新建连接。连接缓存 SHALL NOT 有空闲超时——连接持久存活，直到被显式断开或检测到失效。

#### Scenario: 复用已有会话执行 SFTP 列表

- **WHEN** 已有一条针对某主机的存活会话存在于缓存中，随后调用 `sftp_list`
- **THEN** 该操作复用已有会话，SHALL NOT 触发新的 TCP 连接或 SSH 握手

#### Scenario: 无可用会话时新建连接

- **WHEN** 缓存中不存在针对该主机的可用会话
- **THEN** 新建 SSH 连接并按原有认证流程完成握手与认证

#### Scenario: 切换 tab 后连接保持

- **WHEN** 用户从主机 A 的终端标签切换到主机 B 的标签，随后切回主机 A
- **THEN** 主机 A 的 SSH 连接 SHALL 仍然存活，SHALL NOT 重新握手

## Added Requirements

### Requirement: 显式断开

系统 SHALL 提供 `disconnect_host(host_id)` 方法，移除缓存中该主机的全部会话条目。当最后一个指向某主机的 UI 标签页关闭时，系统 SHALL 调用此方法断开连接。若此时有其他代码持有会话的强引用（如正在执行的 SFTP 操作），会话在最后一个引用释放后断开。

#### Scenario: 关闭最后一个标签页时断开连接

- **WHEN** 用户关闭主机 A 的最后一个标签页（终端或 SFTP）
- **THEN** 系统 SHALL 调用 `disconnect_host` 移除缓存条目，SSH 连接在无其他引用后断开

#### Scenario: 仍有同主机标签页时不断开

- **WHEN** 主机 A 同时有终端和 SFTP 标签页打开，用户关闭其中终端标签页
- **THEN** 系统 SHALL NOT 调用 `disconnect_host`，SSH 连接保持存活

#### Scenario: disconnect_host 后新建连接

- **WHEN** `disconnect_host` 被调用后，用户再次打开该主机的标签页
- **THEN** 系统 SHALL 新建 SSH 连接并完成握手认证
