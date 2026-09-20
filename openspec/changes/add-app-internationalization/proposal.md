## Why

Panda SSH 的提示性文案目前散落在 SwiftUI、原生菜单、Swift 状态模型、Rust 错误分类和日志事件中，中英文混用，且不能随系统或用户偏好切换语言。需要建立完整的简体中文和英语资源及统一呈现规则，避免只翻译界面标签而遗漏错误、安全警告和动态提示。

## What Changes

- 将所有应用维护的提示性字符串抽取为国际化资源：页面与窗口标题、菜单、按钮、占位符、表单说明、校验提示、弹窗、Toast、状态、帮助、无障碍描述，以及程序自身定义的全部 Rust/FFI 错误说明与应用日志事件摘要；覆盖 macOS 与 iPadOS，不以文案来自 Rust 或暂未进入某个 UI 路径为由排除。
- 对全部资源完成 `zh-Hans` 与 `en` 翻译，包括动态参数、数量复数和已有英文提示；双语完整性是完成门禁，不接受仅建空资源或依赖回退掩盖缺失翻译。
- 默认跟随系统首选语言列表匹配已支持语言，无匹配时使用简体中文；设置 → 通用增加“语言”，可选“跟随系统 / 简体中文 / English”，选择持久化到本机应用偏好。
- 手动切换后立即更新应用自有界面和后续提示，不要求重启，不中断 SSH/SFTP、传输或编辑；系统语言变更在应用下次激活或启动时重新解析。
- Rust 保留业务分类、错误与安全参数，Swift 仅负责资源选择及呈现；逐步以语言无关的消息描述替代跨 FFI 传递的最终提示文本，不通过解析中文或英文错误串推断类别。
- 应用生成的日志事件以消息标识和参数支持双语展示；持久化诊断格式保持稳定，历史原始诊断与远端原文不翻译。
- 为资源覆盖、翻译完整性、占位符、语言匹配、持久化、动态切换和业务状态不受影响建立测试先行的验证任务。

## Non-goals

- 不增加第三种翻译、不实现自动机器翻译服务、不改变系统全局语言。
- 不翻译用户输入的主机/分组/片段名称、命令、路径、远端终端输出、远端 SFTP 文件名与服务器原文；不改动协议标识、配置键、符号名、品牌和许可证标识。
- 不翻译异常信息原文（如异常链、堆栈）、底层依赖库返回的错误、纯开发诊断、测试夹具、注释、文档、构建脚本输出及第三方源码；但程序自行编写的错误说明、上下文前缀和恢复建议仍必须纳入资源，不得因其出现在 Rust/FFI 或日志中而排除。
- 不改写历史日志文件或已输出到终端缓冲区的内容；不承诺由操作系统或第三方独立管理的系统界面跟随应用内语言即时切换。
- 不调整 SSH/SFTP、TOFU、凭据、传输、工作区的业务规则，不重设计设置导航，不在本次提案阶段实现代码或填写全部实际翻译条目。

## Capabilities

### New Capabilities

- `app-localization`：提示性字符串资源化、中英完整翻译、参数/复数、错误与数据边界、遗漏检测及回退策略。
- `app-language-settings`：默认跟随系统、语言匹配与回退、设置切换、本机持久化、多窗口即时呈现和会话状态保护。

### Modified Capabilities

- `ffi-bridge`：补充语言无关的用户消息传递契约，保持可编程错误分类、同步外观与敏感信息边界。
- `runtime-logging`：日志事件的本地化呈现与语言无关诊断落盘相分离，明确历史/外部原文的兼容行为。

## Impact

- Swift：`apple/PandaSSH/` 全部用户可见文本及其调用链，重点为 `PandaSSHApp.swift`、`SettingsView.swift`、`Sheets.swift`、`Workspace/`、`Logging/`、`Mock/AppBackend.swift`、`PandaCoreBackend.swift`，新增共享语言呈现上下文与资源目录。
- Rust：`crates/panda-core` 的错误/状态/日志事件描述及 `crates/panda-ffi` 的值适配与对应查询；不迁移业务判断到 Swift，不让 Rust 依赖 Apple 本地化 API。
- 构建：在 `apple/project.yml` 声明双语资源及开发语言；两端应用与测试均验证资源打包。生成的 Swift 绑定和 Xcode 工程仍由既有脚本生成，不手工修改。
- API：保留既有错误变体和同步入口；所有可从生产 UI 到达且可能向用户呈现失败的 `Result<_, PandaError>` 调用 SHALL 以并存的 `*_v2` 结果接口逐项迁移（完整迁移矩阵见下文），旧接口仅作兼容且不得成为新 UI 的提示来源。不得以全局“最近一次错误”旁路关联失败；若实施时发现还需破坏既有签名，应先修订本提案并评审，不能静默破坏兼容性。
- 依赖：拟使用现有 Foundation、SwiftUI、Xcode String Catalog 与 UniFFI；不引入第三方国际化库、不提高 macOS 14 / iPadOS 17 部署基线。
- 并行变更：`migrate-business-logic-to-rust`、`fix-ssh-session-failure-diagnostics`、`preserve-disconnected-session-tabs`、`improve-sftp-task-interactions` 与设置相关变更新增的应用提示，MUST 在合并前登记到本变更定义的提示清单并通过资源审计；它们使用既有 message code/键命名和双语完成规则，冲突时以本变更的资源契约为准。该要求不改变其他 change 的业务规则，也不在本提案中直接改动其他 change。

### FFI v2 迁移矩阵（完整性基线）

本矩阵是提案的评审输入与实现一致性基准。任务 1.2 必须以生产 Swift 调用图与所有 `#[uniffi::export] Result<_, PandaError>` 导出进行双向盘点，逐项登记为“v2 迁移”或“不可从生产 UI 到达”（后者须附调用图、责任人和回归测试）；不得将整个模块或入口组笼统排除。任务 5.2a 对照矩阵核对实现漂移。新增需要描述符的入口 MUST 先补入矩阵再迁移。

| 旧入口 / 字段 | v2 入口或 record | 结果类型 | Swift 切换点 | 兼容期限 |
| --- | --- | --- | --- | --- |
| `connection_failure_classify(error_code)` → `ConnectionFailureFFIRecord` 的 `title`/`detail` | `connection_failure_classify_v2` | 分类 + `MessageDescriptorRecord` 的专用结果 record | `ConnectionGate.swift:216`（生产仅消费 `detail`，`title` 由 Swift 硬编码；v2 起两端均走 descriptor） | 统一政策（见下） |
| `connection_telemetry_list()` → `ConnectionTelemetryRecord.last_error: Option<String>`（及 `owner_kind` 中文标签） | `connection_telemetry_list_v2` | 快照 record，`last_error`/`owner_kind` 均为 descriptor | `ConnectionMonitorView.swift:18`（真实调用点；`PandaCoreBridge.swift:281` 为无调用者死包装，一并清理）与 `:259` 呈现点 | 统一政策（见下） |
| `connection_lifecycle_drain()` → `ConnectionLifecycleRecord.reason: String` | `connection_lifecycle_drain_v2` | 生命周期 record，`reason` 为 descriptor | 当前仓库内无 UI 消费点，监控窗口接入时切换 | 统一政策（见下） |
| `transfer_status` / `transfer_list` → `TransferStatusRecord.error: Option<String>` | `transfer_list_v2`（`transfer_status` 单任务入口当前无 Swift 调用点，登记为不可从生产 UI 到达并附回归测试） | 传输快照，`error: Option<MessageDescriptorRecord>` | `TransferStore.swift:286`（调用）、`:1005` → `TransferPanelView.swift:189-190`（呈现） | 统一政策（见下） |
| `batch_transfer_status` / `batch_transfer_list` → `BatchTransferStatusRecord.error: Option<String>` | `batch_transfer_list_v2`（`batch_transfer_status` 单任务入口当前无 Swift 调用点，同上登记） | 批量快照，`error: Option<MessageDescriptorRecord>` | `TransferStore.swift:332`（调用）、`:1081`/`:1090` → `TransferPanelView.swift:189-190`（呈现） | 统一政策（见下） |
| `test_connection` 与 `sftp_session_*` 入口组（`Result<_, PandaError>`，`Core(String)` 兜底） | 同名 `*_v2` 结果 record | 成功值或失败 descriptor 的结果 record/enum | `PandaCoreBackend.swift:122`（`test_connection`，成功值当前被丢弃）、`ConnectionGate`、`SftpSessionStore.swift:343/101/1065` 等 SFTP 界面链 | 统一政策（见下） |
| `sftp_directory_path`（路径校验，`Core(format!)` 错误） | `sftp_directory_path_v2` | 成功路径或失败 descriptor | `SftpSessionStore.swift:218/226/273`（地址栏归一化） | 统一政策（见下） |
| `shell_open` / `shell_write` / `shell_read` / `shell_close` / `shell_resize`（会话句柄、背压与退出失败） | 同名 `*_v2` 结果 record | 成功值或失败 descriptor 的结果 record/enum | `ShellConnection.swift:37/50/54/58/46+62` ← `TerminalSessionStore.swift:80/30`、`TerminalTabView.swift:402/432/456` | 统一政策（见下） |
| `init_store`、`init_snippets` 及 `ffi_store` 中生产 UI 可达的主机、分组、片段、凭据、主机密钥与导入导出 `Result<_, PandaError>` 入口（`move_group` 当前无调用者，登记为不可达） | 同名 `*_v2` 结果 record | 成功值或失败 descriptor 的结果 record/enum | `PandaCoreBackend`、`SettingsView`（导入导出/凭据保护）、主机/分组/片段界面（逐项调用点见 `inventory/ffi-exports-callgraph.md`） | 统一政策（见下） |
| `connection_health_check`、`start_transfer`、`transfer_cancel` / `transfer_retry` / `transfer_pause` / `transfer_resume` 及批量对应（`start_batch_upload` / `start_batch_download` / `batch_transfer_cancel` / `batch_transfer_resolve_conflict` / `scan_local_batch` / `scan_remote_batch`）的生产 UI 可达 `Result<_, PandaError>` 入口 | 同名 `*_v2` 结果 record | 成功值或失败 descriptor 的结果 record/enum | `ConnectionMonitorView.swift:19`（真实调用点；bridge:285 死包装）、`TransferStore.swift:256/270/274/278/282/299/318/328`、`SftpSessionStore.swift:444/963/978`；迁移时必须消除 `TransferStore.swift:256/282/299/318` 四处 `try!` 的崩溃前提 | 统一政策（见下） |
| `transfer_groups` → `Result<Vec<TransferGroupRecord>, PandaError>` | 当前无 Swift 调用点，登记为不可从生产 UI 到达（附回归测试）；接入时先补本行 v2 | 聚合快照，`group_name` 为 descriptor | 无 | 统一政策（见下） |
| `log_entries(limit)` → `LogEntryRecord.message: String` | `log_entries_v2` | 条目 record，新增 `descriptor: Option<MessageDescriptorRecord>` | `Logger.swift:134`（呈现点 `LogView.swift:41`） | 统一政策（见下） |
| `log_write(level, module, message)`（原始文本写入） | `log_event(descriptor: MessageDescriptorRecord)` | 无返回值；非法 descriptor 拒绝并写 `log.event_rejected` 诊断 | `Logger.swift:104` 的调用方按事件/原始通道分流 | 统一政策（见下） |

**兼容期限（适用于全部行）**：实施期间旧入口保持既有签名与文本语义，只读不改；UI 切换在本变更归档前完成，归档时 UI MUST NOT 再消费旧文本字段；旧入口的删除由归档后的独立清理变更评审执行。消息清单为唯一声明源，并为每个需要保留的旧接口记录 `legacy_wire_text`：该字段是迁移前旧接口输出的逐字兼容基线，不是 UI 译文，初始值必须由迁移前回归夹具导入并以逐字测试锁定。Rust 兼容表仅由此字段生成；`zh-Hans` / `en` catalog 仅用于 UI 呈现，并以同一 message code 与参数模式关联。不得改以某一显示语言资源派生旧文本，也不得在生成表外手写第三份兼容文案。
