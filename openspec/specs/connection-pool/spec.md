# connection-pool Specification

## Purpose

为 Panda SSH 提供 SSH 会话的连接复用与生命周期管理能力，避免每次操作重复建立 TCP + SSH 握手，降低操作延迟与服务器连接负载。连接生命周期由 UI 标签页驱动，切换 tab 时连接保持存活，关闭最后一个指向某主机的标签页时显式断开。

## Requirements

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

### Requirement: 连接失效检测与重连

系统 SHALL 在复用会话前检测其存活状态。若检测到会话已断开或频道打开失败，系统 SHALL 自动将其从缓存中移除并新建连接，对调用方透明。

#### Scenario: 断开会话被检测并替换

- **WHEN** 复用一条已因网络中断而断开的会话
- **THEN** 系统检测到失效，移除旧会话，新建连接并完成操作

### Requirement: 多路频道复用

系统 SHALL 支持在单个复用的 `SshSession` 上同时打开多个频道（终端 shell、SFTP 子系统、exec），满足同一主机下终端与 SFTP 并发使用的需求。

#### Scenario: 终端与 SFTP 共享同一连接

- **WHEN** 用户已打开某主机的终端标签，随后在同一主机打开 SFTP 标签
- **THEN** SFTP 操作复用终端持有的同一会话，SHALL NOT 新建独立连接

### Requirement: 线程安全

连接缓存的获取、归还、断开操作 SHALL 是线程安全的，支持在多线程 / 多 tokio task 环境下并发访问而不引发数据竞争或重复断开。

#### Scenario: 并发获取同一主机会话

- **WHEN** 两个 tokio task 同时请求同一主机的会话
- **THEN** 两者均获得有效的独立频道，SHALL NOT 共享同一频道或触发竞态
