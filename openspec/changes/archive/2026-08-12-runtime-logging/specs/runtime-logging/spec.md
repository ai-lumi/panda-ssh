## Purpose

运行时日志记录与展示：在应用运行期间捕获关键事件与错误，通过内存环形缓冲区供 UI 即时展示，同时持久化到文件供事后排查。

## ADDED Requirements

### Requirement: 日志级别

系统 SHALL 支持四个日志级别：debug、info、warning、error。每条日志 MUST 携带其级别。UI 展示时 MUST 按级别着色区分。

#### Scenario: 不同级别日志同时存在

- **WHEN** 依次记录 debug、info、warning、error 四条日志
- **THEN** UI 日志窗口中四条日志各自显示对应级别的颜色标识

### Requirement: 日志条目格式

每条日志 SHALL 包含时间戳、级别、模块名和消息文本。格式 MUST 为 `[ISO8601 时间戳] [级别] [模块] 消息`。文件与 UI 中 MUST 使用相同格式。

#### Scenario: 日志条目格式校验

- **WHEN** 记录一条 info 级别、模块为 `SSH`、消息为 `已连接` 的日志
- **THEN** 该条目的文本表示包含 ISO8601 时间戳、`INFO`、`SSH` 和 `已连接` 四个部分

### Requirement: 内存环形缓冲区

系统 SHALL 在内存中维护一个环形缓冲区，最多保留 1000 条日志。当缓冲区已满时，新日志 MUST 先移除最旧条目再添加。UI 日志窗口 MUST 展示该缓冲区的当前内容。

#### Scenario: 缓冲区未满

- **WHEN** 已记录 500 条日志
- **THEN** 内存缓冲区包含 500 条日志，UI 窗口展示全部 500 条

#### Scenario: 缓冲区满后丢弃最旧

- **WHEN** 已记录 1000 条日志后再记录第 1001 条
- **THEN** 内存缓冲区仍包含 1000 条，最旧条目被丢弃，第 1001 条出现在末尾

### Requirement: 文件日志持久化

系统 SHALL 将日志条目追加写入到文件。日志文件路径 MUST 位于应用配置目录下的 `logs/` 子目录（macOS 为 `~/.panda-ssh/logs/panda-ssh.log`，iPadOS 为 App Group 容器内 `logs/panda-ssh.log`）。

#### Scenario: 日志写入文件

- **WHEN** 记录一条日志
- **THEN** 该条目被追加写入到日志文件末尾

#### Scenario: 应用重启后文件继续追加

- **WHEN** 应用重启后记录新日志
- **THEN** 新日志追加到已有文件末尾，不覆盖历史内容

### Requirement: 文件大小轮转

系统 SHALL 在日志文件大小达到 100MB 时自动轮转。轮转 MUST 将当前文件重命名为备份文件并创建新文件继续写入。系统 MUST 只保留一个备份文件（覆盖旧备份）。

#### Scenario: 文件达到 100MB 时轮转

- **WHEN** 日志文件大小达到 100MB 且新日志需要写入
- **THEN** 当前文件被重命名为 `panda-ssh.log.1`，新日志写入新建的 `panda-ssh.log`

#### Scenario: 轮转覆盖旧备份

- **WHEN** 日志文件再次达到 100MB 且已存在 `panda-ssh.log.1`
- **THEN** 旧的 `panda-ssh.log.1` 被覆盖，当前文件重命名为新的 `panda-ssh.log.1`

### Requirement: UI 日志窗口

系统 SHALL 提供一个 UI 窗口展示内存缓冲区中的日志条目。窗口 MUST 在新日志到达时自动滚动到底部。窗口 MUST 提供清除按钮以清空内存缓冲区。

#### Scenario: 新日志自动滚动

- **WHEN** 日志窗口已打开且缓冲区已满，新日志被记录
- **THEN** 窗口滚动到底部，显示最新的日志条目

#### Scenario: 清除日志

- **WHEN** 用户点击清除按钮
- **THEN** 内存缓冲区被清空，UI 窗口不再显示任何条目（文件内容不受影响）

### Requirement: 日志规范

系统 SHALL 为每个模块定义统一的日志记录规范，包括模块名、日志级别使用约定和消息内容要求。所有模块的日志调用 MUST 遵守此规范。

**模块名约定**：模块名 MUST 使用大写英文标识，各模块及其名称如下：
- `SSH` — SSH 连接与终端会话
- `SFTP` — SFTP 文件操作与目录浏览
- `Transfer` — 文件传输任务管理
- `HostKey` — 主机密钥验证与 TOFU
- `Config` — 配置加载与 iCloud 同步
- `FFI` — Rust FFI 桥接层调用

**日志级别使用约定**：
- `error`：操作失败且影响用户使用（连接断开、传输失败、FFI 异常、同步失败）
- `warning`：可恢复的异常或需要用户注意（密钥变更、TOFU 待确认、凭据缺失、覆盖冲突）
- `info`：正常操作的关键节点（连接成功、传输完成、同步成功、配置加载完成）
- `debug`：开发调试信息（FFI 调用参数摘要、内部状态变化），Release 构建中 SHALL 仍写入内存缓冲区但 MAY 跳过文件写入

**消息内容要求**：
- error 日志 MUST 包含错误描述（错误类型 + 错误消息）
- 涉及主机的日志 MUST 包含主机名或地址标识（`host:port` 格式）
- 涉及传输任务的日志 MUST 包含任务名称或文件路径

**安全红线**：
- 日志 MUST NOT 包含密码、私钥、口令等敏感信息
- 日志 MUST NOT 包含密钥文件完整路径
- 认证方式（密码/密钥）SHALL 记录，但不记录凭据内容

#### Scenario: 错误日志包含足够上下文

- **WHEN** SSH 连接失败（认证错误）
- **THEN** 日志记录为 error 级别，模块为 `SSH`，消息包含主机地址、端口和错误描述

#### Scenario: 敏感信息不出现在日志中

- **WHEN** 用户使用密码认证连接主机
- **THEN** 日志记录认证方式为「密码认证」，但不包含密码明文

#### Scenario: 正常操作记录为 info

- **WHEN** SFTP 连接成功建立
- **THEN** 日志记录为 info 级别，模块为 `SFTP`，消息包含主机名和连接状态

### Requirement: 平台入口

在 macOS 上，日志窗口 SHALL 通过菜单栏命令打开（快捷键 ⌘⇧L）。在 iPadOS 上，日志页面 SHALL 通过侧栏底部入口切换展示。

#### Scenario: macOS 打开日志窗口

- **WHEN** 用户按下 ⌘⇧L 或选择菜单「窗口 → 日志」
- **THEN** 打开独立的日志窗口

#### Scenario: iPadOS 切换到日志页

- **WHEN** 用户在侧栏底部点击「日志」入口
- **THEN** 主区域切换到全屏日志页面

