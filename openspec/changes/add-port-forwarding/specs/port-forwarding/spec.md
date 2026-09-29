## Purpose

SSH 端口转发/隧道管理：支持本地转发、反向转发和动态转发（SOCKS5），按所有者独占连接，明确监听范围、生命周期和端口冲突处理。

## ADDED Requirements

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
