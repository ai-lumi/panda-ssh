## MODIFIED Requirements

### Requirement: 连接复用

系统 SHALL 维护一个以 `(host_id, credentials)` 为键的连接缓存。对同一主机的后续操作优先复用缓存中已有的可用 `SshSession`，SHALL NOT 在无可用会话时直接新建连接。连接缓存 SHALL NOT 有空闲超时——连接持久存活，直到被显式断开或检测到失效。已打开终端页签的 shell 会话 SHALL 在用户切换到其他页签时保持存活，SHALL NOT 因 UI 视图切换被关闭或重新初始化。

#### Scenario: 复用已有会话执行 SFTP 列表

- **WHEN** 已有一条针对某主机的存活会话存在于缓存中，随后调用 `sftp_list`
- **THEN** 该操作复用已有会话，SHALL NOT 触发新的 TCP 连接或 SSH 握手

#### Scenario: 无可用会话时新建连接

- **WHEN** 缓存中不存在针对该主机的可用会话
- **THEN** 新建 SSH 连接并按原有认证流程完成握手与认证

#### Scenario: 切换 tab 后连接保持

- **WHEN** 用户从主机 A 的终端标签切换到主机 B 的标签，随后切回主机 A
- **THEN** 主机 A 的 SSH 连接和终端 shell SHALL 仍然存活，SHALL NOT 重新握手或重新初始化

#### Scenario: 多次切换后终端会话保持

- **WHEN** 用户在两个或更多已连接终端标签之间反复切换
- **THEN** 每个未关闭标签的 SSH 连接和 shell SHALL 保持其原有会话，不得因非活动状态被关闭
