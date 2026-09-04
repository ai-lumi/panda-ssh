## Why

当前按 `(host_id, credentials)` 全局复用 SSH Transport 的连接池把多个终端、SFTP 标签和后台传输耦合到同一 Socket。实测一次终端重试可并发创建两个 Socket，而任一共享 Socket 的延迟关闭又会让同主机多个会话同时中断；现有主机级 `disconnect_host` 与 30 秒 inactivity timeout 进一步放大了生命周期不确定性，且关键断开路径缺少日志。

## What Changes

- **BREAKING** 删除跨终端、跨 SFTP 标签和跨传输任务的隐式全局 Socket 复用；每个会话所有者显式持有并释放自己的 SSH Transport。
- 每个终端标签独占一个 Socket 和一个 shell Channel；`exit` 关闭该标签拥有的 Channel 与 Socket，不影响同主机其他标签。
- 终端重试只提交一次建连，并为该标签建立一个新的 Socket；在途重复请求不得创建额外 Transport。
- 每个 SFTP 标签持有独立的长连接句柄，目录浏览和远端文件操作复用该标签自己的 SFTP 会话，而不是按主机全局复用。
- 每个后台单文件或批量传输任务持有独立连接，任务完成、失败或取消后释放，不依赖来源 SFTP 标签。
- **BREAKING** FFI 从主机级 `disconnect_host` 与无状态 SFTP 调用迁移为稳定连接/会话句柄上的精确关闭与操作。
- 移除已认证连接的 30 秒 inactivity timeout，保留 SSH keepalive 及有限失败次数，以区分空闲与不可用。
- 连接监控展示非敏感的所有者关联；日志记录 Channel 正常结束、Socket 异常关闭、显式关闭及重试，且包含主机地址与运行时连接标识。
- macOS 与 iPadOS 使用相同的显式所有权语义；仅平台 UI 呈现保持既有差异。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `connection-pool`: 用显式、按所有者隔离的连接生命周期替代跨 Session 全局复用和主机级断开。
- `ssh-connection`: 每次连接请求建立独立会话，关闭 inactivity timeout，并明确终端 Channel 与 Transport 的释放关系。
- `shell-terminal`: 明确终端独占 Transport、`exit` 隔离和单次重试语义。
- `ffi-bridge`: 改为按稳定句柄打开、操作和关闭终端/SFTP 连接，并移除主机级断开契约。
- `workspace`: 终端标签、SFTP 标签和后台传输分别拥有连接，关闭与重试按所有者精确执行。
- `transfers`: 单文件传输拥有独立连接并在终态释放。
- `sftp-batch-transfer`: 批量传输任务拥有独立连接并在终态释放。
- `connection-monitoring`: 展示连接所有者关联，并准确区分正常结束与异常关闭。
- `runtime-logging`: 补充 SSH Channel 与 Socket 生命周期日志要求。

## Non-goals

- 不改变 SSH 协议实现、密码/密钥认证、TOFU 与 known_hosts 行为。
- 不改变传输并发数、暂停、继续、取消、冲突处理和失败重试的产品语义。
- 不在本次变更中实现跨进程 OpenSSH ControlMaster 或重新引入任何自动跨标签复用策略。
- 不增加持久化监控历史，也不记录命令、终端输出、凭据或完整私钥路径。
- 不改变 macOS 独立监控窗口与 iPadOS 工作区内监控页面的既有呈现方式。

## Impact

- Rust：`panda-core` 的 SSH 连接配置、连接池模块与会话生命周期，`panda-ffi` 的 shell/SFTP/传输注册表及生命周期。
- FFI：UniFFI 导出函数、生成 Swift 绑定和 C 头文件发生破坏性契约调整。
- Swift：终端、SFTP、工作区关闭协调、传输调用和运行时日志接线。
- 测试：Rust fake SSH server 集成测试、FFI 生命周期测试、Swift 状态机/XCTest，以及覆盖率与双平台构建门禁。
- 依赖与配置：不新增第三方依赖，不改变配置文件格式或凭据存储。
