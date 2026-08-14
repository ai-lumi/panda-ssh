# connection-pool Specification

## Purpose

为 Panda SSH 提供 SSH 会话的连接复用与生命周期管理能力，避免每次操作重复建立 TCP + SSH 握手，降低操作延迟与服务器连接负载。

## ADDED Requirements

### Requirement: 连接复用

系统 SHALL 维护一个以 `(host_id, credentials)` 为键的连接池。对同一主机的后续操作优先复用池内已有的可用 `SshSession`，SHALL NOT 在无可用会话时直接新建连接。

#### Scenario: 复用已有会话执行 SFTP 列表

- **WHEN** 已有一条针对某主机的存活会话存在于池中，随后调用 `sftp_list`
- **THEN** 该操作复用已有会话，SHALL NOT 触发新的 TCP 连接或 SSH 握手

#### Scenario: 无可用会话时新建连接

- **WHEN** 池中不存在针对该主机的可用会话
- **THEN** 新建 SSH 连接并按原有认证流程完成握手与认证

### Requirement: 空闲超时回收

系统 SHALL 对池内连接维护空闲超时机制（默认 30 秒）。会话自上一次被使用后超过空闲超时时间未被再次使用，系统 SHALL 自动断开并移出连接池。

#### Scenario: 空闲会话被自动回收

- **WHEN** 某会话在池中空闲超过 30 秒
- **THEN** 系统自动关闭该会话并将其从池中移除

#### Scenario: 活跃会话不被回收

- **WHEN** 某会话在 30 秒内被再次用于 SFTP 或终端操作
- **THEN** 该会话保持可用，SHALL NOT 被回收

### Requirement: 连接失效检测与重连

系统 SHALL 在复用会话前检测其存活状态。若检测到会话已断开或频道打开失败，系统 SHALL 自动将其从池中移除并新建连接，对调用方透明。

#### Scenario: 断开会话被检测并替换

- **WHEN** 复用一条已因网络中断而断开的会话
- **THEN** 系统检测到失效，移除旧会话，新建连接并完成操作

### Requirement: 多路频道复用

系统 SHALL 支持在单个复用的 `SshSession` 上同时打开多个频道（终端 shell、SFTP 子系统、exec），满足同一主机下终端与 SFTP 并发使用的需求。

#### Scenario: 终端与 SFTP 共享同一连接

- **WHEN** 用户已打开某主机的终端标签，随后在同一主机打开 SFTP 标签
- **THEN** SFTP 操作复用终端持有的同一会话，SHALL NOT 新建独立连接

### Requirement: 线程安全

连接池的获取、归还、回收操作 SHALL 是线程安全的，支持在多线程 / 多 tokio task 环境下并发访问而不引发数据竞争或重复回收。

#### Scenario: 并发获取同一主机会话

- **WHEN** 两个 tokio task 同时请求同一主机的会话
- **THEN** 两者均获得有效的独立频道，SHALL NOT 共享同一频道或触发竞态
