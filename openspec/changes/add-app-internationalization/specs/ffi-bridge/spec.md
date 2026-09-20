## MODIFIED Requirements

### Requirement: 错误分类

FFI 错误 MUST 保留可编程区分的类别：`AuthFailed`、`Timeout`、`HostKeyMismatch { stored, presented }`、`UnknownHostKey { host, fingerprint }`、`NotInitialized`、`UnknownHost`、`MissingPassword`、`MissingPassphrase`、凭据保护错误及 `Core(String)`（兜底）。SHALL NOT 把可区分的 core 错误一律压平为字符串。应用用户提示 SHALL 根据结构化类别或消息描述本地化，MUST NOT 通过匹配某种语言的错误文本来决定业务行为，MUST NOT 直接以 `Core(String)` 或内部错误描述充当唯一用户提示。

#### Scenario: 认证失败可区分

- **WHEN** 密码错误导致连接失败
- **THEN** Swift 侧收到 `AuthFailed`，可与超时、网络错误区分处理

#### Scenario: 主机密钥问题携带指纹

- **WHEN** 发生 Mismatch 或 Reject 策略下的 Unknown
- **THEN** 错误以结构化字段携带相关指纹，UI 可直接展示

#### Scenario: 同一错误以两种语言展示

- **WHEN** 同一个认证失败分别在简体中文和英语模式中呈现
- **THEN** 业务错误类别保持相同，用户提示分别使用对应译文，不改变认证或重试策略

#### Scenario: 兜底错误安全呈现

- **WHEN** 收到仅有外部诊断文本的 `Core(String)` 错误
- **THEN** UI 显示本地化通用错误摘要，仅在必要时展示经过安全处理的技术详情，不以原文解析恢复类别

## ADDED Requirements

### Requirement: 语言无关的用户消息契约

FFI SHALL 为程序自身定义的全部 Rust/FFI 错误说明、连接失败、终态原因、传输失败及应用日志事件提供稳定的消息标识和有类型、含义明确的参数，并具有完整中英译文，不以当前 UI 是否使用作为排除依据。跨边界 descriptor MUST 为 `MessageDescriptorRecord { schema_version, code, parameters, technical_detail }`：`schema_version` 为无符号 16 位整数；`code` 为稳定的小写点分语义键；`parameters` 是按名称排序、名称唯一的 `MessageParameterRecord` 列表；每个参数仅可为 string、signed 64-bit integer、unsigned 64-bit integer 或 bool，且其 tag 与唯一设置的值字段一致。已发布 code 的参数名、类型、语义和安全级别 MUST NOT 改变；新参数 MUST 使用新 code 或新 schema version。`technical_detail` MUST 是可选、已脱敏的外部原文，MUST NOT 承载应用固定说明或凭据、私钥材料、保护密钥、完整私钥路径。

异常信息原文、底层依赖库错误、远端返回和用户输入无需翻译，应用添加的固定说明 MUST 与这些原文分离并资源化。支持运行中语言切换的调用方 SHALL 在呈现时选择语言，业务结果 MUST 不依赖调用方的语言。跨边界数据 MUST 使用平台无关的简单值类型，分类与安全参数提取 MUST 属于 Rust 核心职责，Swift MUST 仅进行资源映射和呈现。既有 `PandaError` 及入口签名 MUST 保留，且不得修改既有错误 variant 的关联值形状；所有可从生产 UI 到达且可能向用户呈现失败的 `Result<_, PandaError>` 入口 SHALL 增加并行 `*_v2` 结果接口，并在同一结果中关联业务结果或失败 descriptor。盘点必须同时覆盖生产 Swift 调用图和全部 `#[uniffi::export] Result<_, PandaError>` 导出；未迁移项仅可在记录不可达依据、责任人和回归测试后保留。新 UI MUST 使用 v2，旧接口不得依赖全局最近错误补充 descriptor。新增接口 SHALL 保持同步外观、全局 runtime 和会话所有权规则。

既有入口到 `*_v2` 的迁移 SHALL 由受版本控制的迁移矩阵管理，矩阵逐项记录旧入口或字段、v2 入口或 record、结果类型、Swift 切换点与兼容期限；实现与矩阵不一致 MUST 失败，新增需要描述符的入口 MUST 先登记矩阵再迁移。兼容期内旧接口 MUST 保持既有签名与文本语义：每项固定旧文本 SHALL 由消息清单中的 `legacy_wire_text` 确定性生成，且与迁移前可观察输出逐字一致；该字段不是显示译文，MUST NOT 由 `zh-Hans` 或 `en` catalog 派生。UI 迁移完成后 MUST NOT 继续消费旧接口的最终提示文本，旧接口的移除 SHALL 经后续变更评审。

#### Scenario: 全部程序自定义错误均有翻译

- **WHEN** 遍历程序自行定义的 Rust/FFI 错误及其固定上下文说明，包括尚未被某个界面使用的错误
- **THEN** 每条说明都有消息标识及完整中英译文，不以兜底错误或原始异常为由漏掉程序自定义文案

#### Scenario: 依赖异常原文与程序说明分离

- **WHEN** 依赖库返回异常 `Permission denied`，程序添加“读取配置失败”的上下文说明
- **THEN** 上下文说明具有中英译文，`Permission denied` 原文无需翻译，仍遵循敏感信息保护要求

#### Scenario: 一份失败快照可重新本地化

- **WHEN** UI 保存了一份连接失败或传输失败快照，然后切换显示语言
- **THEN** 可直接使用原快照中的消息标识和参数生成新译文，无需重连、重试任务或重新解析原文

#### Scenario: 安全警告参数完整

- **WHEN** Rust 报告主机密钥变更
- **THEN** 消息保留主机标识、已存储指纹和当前指纹等安全字段，两种译文都能无损呈现，且不附带凭据、私钥或禁止披露的私钥完整路径

#### Scenario: 未知消息标识

- **WHEN** 调用方收到无法识别的消息标识
- **THEN** 使用本地化通用失败提示，保留业务失败状态，不崩溃、不将内部标识当作用户文案

#### Scenario: 既有调用与绑定兼容

- **WHEN** 生成新 Swift 绑定并构建 macOS 和 iPadOS 应用
- **THEN** 既有错误类别和同步调用入口仍可使用，新增消息描述不引入第二个 runtime、不改变会话句柄归属

#### Scenario: 并发失败不串联描述

- **WHEN** 两个并行连接分别返回不同的 v2 失败结果
- **THEN** 每个结果仅携带本次调用的 descriptor 与安全参数，不读取或覆盖进程全局的最近一次失败

#### Scenario: 迁移矩阵与实现一致

- **WHEN** 审计每个需要 descriptor 的既有入口及其 v2 替代
- **THEN** 每个旧入口或字段都能在矩阵中找到对应的 v2 入口、结果类型、Swift 切换点与兼容期限，未登记的入口迁移导致审计失败

#### Scenario: 兼容期结束后的清理

- **WHEN** 本变更完成 UI 切换并归档
- **THEN** UI 不再读取旧接口的最终提示文本，旧接口保持既有签名与由 `legacy_wire_text` 生成的兼容文本，直至经评审的清理变更移除

#### Scenario: 旧接口文本逐字兼容

- **WHEN** 迁移前后以相同参数调用一个保留的旧 FFI 入口
- **THEN** 其固定文本输出与迁移前逐字相同，包括原有语言、空格和换行；UI 译文变化不会改变该输出

#### Scenario: Shell 失败同次携带描述符

- **WHEN** 生产 UI 调用 `shell_open`、`shell_write`、`shell_read`、`shell_close` 或 `shell_resize` 的 v2 入口失败
- **THEN** 同次结果携带对应的 descriptor 与安全参数，UI 无需解析旧 `PandaError` 文本或读取全局最近错误
