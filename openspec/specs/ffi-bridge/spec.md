# ffi-bridge Specification

## Purpose

通过 uniffi 把 panda-core 暴露给 SwiftUI（macOS / iPadOS）。FFI 层只做翻译与生命周期管理，不含业务逻辑。
## Requirements

### Requirement: FFI 模块边界与覆盖率责任

FFI 实现 SHALL 将无状态纯值适配器与拥有业务状态、资源生命周期、持久化副作用或错误策略的实现分离。只有纯值适配器模块 MAY 被覆盖率文件级排除；会话、传输、TOFU、凭据、日志、遥测、工作区和终端状态机 MUST 继续计入 Rust lines 与 regions 覆盖率门禁。模块拆分 MUST NOT 改变既有 UniFFI 导出名称、参数、返回类型或同步调用外观。

#### Scenario: 纯适配器可独立审查

- **WHEN** 覆盖率配置排除 FFI 纯适配器模块
- **THEN** 被排除模块仅包含无状态值转换或 core 函数转发，且不访问 runtime、store、会话/任务注册表、网络或文件系统

#### Scenario: 业务 FFI 仍受门禁约束

- **WHEN** 运行 Rust 覆盖率门禁
- **THEN** 会话句柄、传输调度、TOFU、持久化、日志、遥测、工作区和终端状态机所在模块均被统计，且 lines 与 regions MUST 分别不低于 95%

#### Scenario: 拆分保持 Swift 契约

- **WHEN** FFI 内部模块被拆分后生成 Swift 绑定
- **THEN** 既有 Swift 调用可继续以相同导出名称、参数和返回类型构建及运行

### Requirement: 导出接口

FFI 层 SHALL 导出：`init_store(config_dir)`、`list_hosts`、`save_host`、`delete_host`、`list_groups`、`save_group`、`delete_group`、`move_group`、`save_credential`、`read_credential`、`delete_credential`、`set_credential_protection_key`、`credential_protection_enabled`、`test_connection`、兼容性无状态 `sftp_*`、`host_key_status(host, port)`、`accept_unknown_host_key(host, port, key)`；并 SHALL 导出 `shell_open` / `shell_read` / `shell_write` / `shell_resize` / `shell_close`、`sftp_session_open` / `sftp_session_*` / `sftp_session_close` 以及连接遥测查询接口。连接入口（`test_connection`、无状态 `sftp_*`、`shell_open`、`sftp_session_open`）MUST 接受 `trust_on_first_use: bool` 参数：`false` 时对未知主机密钥使用 `Reject` 策略，`true` 时使用 `AcceptAndStore`。类型以 FFI 友好的 Record/Enum 暴露（`HostConfigRecord`、`AuthMethodEnum`、`RemoteFileRecord`、`GroupRecord`），错误以结构化 `PandaError` 暴露（见「错误分类」）。`save_host` / `save_group` 传入空 id 时 MUST 生成新 UUID。`HostConfigRecord` MUST 携带 `group_id: Option<String>` 表示主机归属分组（`None` 为根级）。`delete_group` MUST 级联清空被删分组（含子分组）下所有主机的 `group_id`，并一并删除子分组；`move_group` MUST 拒绝会造成环的移动（移入自身或后代分组）。

#### Scenario: Swift 绑定可生成

- **WHEN** 运行 `apple/Scripts/build-rust.sh`（手动/CI 验证步骤）
- **THEN** 生成 Swift 绑定源码与 XCFramework，其中 macOS slice MUST 同时支持 `arm64` 与 `x86_64`，iOS device 与 simulator slice 保持既有 arm64 支持

#### Scenario: 远程文件管理可达 UI

- **WHEN** Swift 侧调用无状态 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir` 或对应的 `sftp_session_*` 句柄接口
- **THEN** 对应 core 的 SFTP 管理能力被执行

#### Scenario: 分组管理可达 UI

- **WHEN** Swift 侧调用 `list_groups` / `save_group` / `delete_group` / `move_group`
- **THEN** 对应 core 的分组管理与删除级联清理被执行

#### Scenario: 未知主机密钥决策权在 UI

- **WHEN** Swift 以 `trust_on_first_use=false` 连接未知主机
- **THEN** 返回 `UnknownHostKey` 错误（携带呈现密钥与指纹），known_hosts 不被写入

#### Scenario: 指纹状态可查询

- **WHEN** Swift 调用 `host_key_status(host, port)`
- **THEN** 返回该主机的三态状态（Unknown / Match / Mismatch），供 UI 决定直接连接、弹确认框或阻断告警

### Requirement: 同步调用语义

所有导出函数对调用方 MUST 表现为同步调用；内部异步逻辑 SHALL 在懒初始化的全局 tokio runtime 上执行。同步调用 MUST NOT 阻塞主线程；阻塞型调用（SSH/SFTP 连接、网络往返）SHALL 由调用方在非主线程执行，并 SHALL 支持多个连接并行建立。

#### Scenario: 从任意线程调用

- **WHEN** Swift 侧从非 tokio 线程调用导出函数
- **THEN** 正常返回结果或错误，不发生 block_on 嵌套 panic

#### Scenario: 连接建立不阻塞主线程

- **WHEN** 用户打开 SSH 或 SFTP 标签，连接握手（DNS/网络/认证）耗时较长
- **THEN** 主线程不被占用，页面可正常交互（滚动、切换标签、打开其他连接），连接结果稍后回传

#### Scenario: 多个连接并行建立

- **WHEN** 用户先后为多台主机打开连接标签，网络延迟较高
- **THEN** 各主机连接并行握手，互不排队；任一连接完成即可呈现，无需等待其他连接

### Requirement: 凭据边界

FFI 层 SHALL 将凭据的保存、读取、删除和保护密钥状态管理委托给跨平台核心，且 SHALL NOT 访问系统钥匙串。密码、私钥口令与保护密钥 MUST 仅作为调用参数在内存中传递，MUST NOT 由 Swift 侧落盘。SSH/SFTP 连接入口 SHALL 使用瞬态密码或口令参数为声明的所有者建立独立连接；SFTP 句柄后续操作 SHALL 仅复用该标签自己拥有的会话，MUST NOT 跨所有者复用连接。

#### Scenario: 缺密码时报错

- **WHEN** 对密码认证的主机调用 `test_connection` 但未传 password
- **THEN** 返回 `MissingPassword` 错误

### Requirement: 初始化

`init_store(config_dir)` 设置当前进程的配置目录；未初始化时调用其他接口 MUST 返回 `NotInitialized`。App 生命周期内只调用一次；测试场景允许重新初始化以切换临时目录。

#### Scenario: 未初始化调用

- **WHEN** 未调用 `init_store` 直接调用 `list_hosts`
- **THEN** 返回 `NotInitialized` 错误

#### Scenario: 集成测试切换临时目录

- **GIVEN** 进程内已调用过 `init_store`
- **WHEN** 在同进程中再次调用 `init_store` 指向新的临时目录
- **THEN** 后续 store 操作使用新的临时目录

### Requirement: 错误分类

FFI 错误 MUST 保留可编程区分的类别：`AuthFailed`、`Timeout`、`HostKeyMismatch { stored, presented }`、`UnknownHostKey { host, fingerprint }`、`NotInitialized`、`UnknownHost`、`MissingPassword`、`MissingPassphrase`、凭据保护错误及 `Core(String)`（兜底）。SHALL NOT 把可区分的 core 错误一律压平为字符串。

#### Scenario: 认证失败可区分

- **WHEN** 密码错误导致连接失败
- **THEN** Swift 侧收到 `AuthFailed`，可与超时、网络错误区分处理

#### Scenario: 主机密钥问题携带指纹

- **WHEN** 发生 Mismatch 或 Reject 策略下的 Unknown
- **THEN** 错误以结构化字段携带相关指纹，UI 可直接展示

### Requirement: 启动传输任务

`start_transfer` SHALL 接受 `size` 参数；对于下载任务 SHALL 使用该值作为总大小；对于上传任务，当 `size` 为 0 时 SHALL 从本地文件计算，否则 SHALL 使用传入值。

#### Scenario: 下载任务带大小启动

- **GIVEN** 调用 `start_transfer(direction=Download, size=300_000_000, ...)`
- **WHEN** 任务入队
- **THEN** 任务总大小为 300_000_000 字节

#### Scenario: 上传任务未传大小

- **GIVEN** 调用 `start_transfer(direction=Upload, size=0, local_path="/local/f.bin", ...)`
- **WHEN** 任务入队
- **THEN** 任务总大小等于 `/local/f.bin` 的实际大小

### Requirement: 覆盖确认请求可跨 FFI 边界传递

FFI 层 SHALL 将 `panda-core` 的覆盖确认请求以结构化类型暴露给 Swift，使 UI 可展示源文件与目标文件的大小、最后修改时间，并回传用户决策。

#### Scenario: Swift 收到结构化覆盖确认

- **WHEN** Swift 调用 `sftp_upload` / `sftp_download` 且目标文件已存在
- **THEN** FFI 返回一个可区分的错误/结果变体，携带 `source_size`、`source_mtime`、`target_size`、`target_mtime` 字段，而不是仅返回字符串错误

#### Scenario: 用户决策可回传至 Rust

- **GIVEN** Swift 已收到覆盖确认请求
- **WHEN** 用户在弹窗中选择「覆盖」或「跳过」
- **THEN** Swift 通过 FFI 提供的机制（如同步弹窗返回布尔值，或拆分为 `sftp_upload_with_overwrite` 接口）将决策回传给 Rust 并继续执行

### Requirement: 不破坏现有 FFI 调用语义

新增覆盖确认流程 SHALL 保持现有 FFI 函数对调用方的同步外观；异步逻辑仍 SHALL 在全局 tokio runtime 上 `block_on` 执行。覆盖确认弹窗由 Swift UI 层负责，Rust 侧 SHALL 在需要确认时通过错误/结果变体告知 UI，而不是自行阻塞等待用户输入。

#### Scenario: 未触发覆盖时行为不变

- **WHEN** 目标文件不存在，调用 `sftp_upload` / `sftp_download`
- **THEN** 行为与变更前完全一致，直接完成传输

### Requirement: 传输任务状态机

单文件传输任务 SHALL 在成功获取并发许可证后才进入 `Running` 状态；等待许可证期间 SHALL 保持 `Queued` 状态。

#### Scenario: 超出并发上限的任务排队

- **GIVEN** 并发上限为 3，已存在 3 个运行中任务
- **WHEN** 添加第 4 个上传任务
- **THEN** 该任务状态为 `Queued`，前 3 个任务之一完成后它才变为 `Running`

#### Scenario: 取消排队任务

- **GIVEN** 一个状态为 `Queued` 的任务
- **WHEN** 调用取消
- **THEN** 任务立即变为 `Cancelled`，不占用许可证

### Requirement: 连接遥测 FFI 查询

FFI 层 SHALL 导出同步的连接遥测快照查询与针对指定连接标识的健康检查接口。导出记录 MUST 分别提供传输 I/O 状态、SSH keepalive 状态和通道状态，且使用 FFI 友好的简单值类型；平台可用的内核 TCP 状态为可选字段。MUST NOT 包含凭据、终端内容、命令文本或文件内容。健康检查的异步工作 SHALL 在既有全局 tokio runtime 上执行。

#### Scenario: Swift 查询连接快照
- **WHEN** Swift 在非主线程调用连接遥测快照查询接口
- **THEN** 接口返回当前内存快照或空列表，且不阻塞主线程、不建立新 SSH 连接

#### Scenario: 不存在的连接标识
- **WHEN** Swift 对已释放或不存在的连接标识调用健康检查接口
- **THEN** 接口返回可区分的未找到结果或错误，且 MUST NOT 创建新连接

### Requirement: 显式会话句柄

FFI 层 SHALL 为终端与 SFTP 打开操作返回稳定、FFI 友好的会话句柄；后续读写、文件操作、健康检查与关闭 SHALL 明确指定句柄。句柄 MUST 绑定单一所有者，关闭一个句柄 MUST NOT 按主机关闭其他句柄。异步工作 SHALL 继续在既有全局 tokio runtime 上执行。

#### Scenario: 两个同主机 SFTP 句柄

- **WHEN** Swift 为同一主机打开两个 SFTP 标签
- **THEN** FFI 返回两个不同句柄，任一句柄关闭后另一个仍可执行目录列表

#### Scenario: 已关闭句柄被再次使用

- **WHEN** Swift 使用已关闭或不存在的会话句柄执行操作
- **THEN** FFI 返回可区分的句柄无效错误，MUST NOT 建立新连接或影响其他句柄

### Requirement: 精确关闭契约

FFI SHALL 提供终端和 SFTP 会话的幂等精确关闭接口，并 SHALL NOT 暴露会批量断开某主机全部活动连接的正常工作区关闭路径。

#### Scenario: 精确关闭终端句柄

- **GIVEN** 同一主机有两个活动终端句柄
- **WHEN** Swift 关闭其中一个句柄
- **THEN** 仅对应 Channel 与 Transport 被释放，另一个句柄保持有效
