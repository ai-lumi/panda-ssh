## MODIFIED Requirements

### Requirement: 错误分类

FFI 错误 MUST 保留可编程区分的类别：`AuthFailed`、`Timeout`、`HostKeyMismatch { stored, presented }`、`UnknownHostKey { host, fingerprint }`、`NotInitialized`、`UnknownHost`、`MissingPassword`、`MissingPassphrase`、凭据保护错误及 `Core(String)`（兜底）。SHALL NOT 把可区分的 core 错误一律压平为字符串。

交互式 shell 接口 SHALL 额外区分输入背压、输入过大、正常结束、原因未知的远端关闭及会话故障。会话故障 SHALL 携带安全的阶段、类别和可用的错误码、退出码或信号类别；相同故障在读、写和最终状态查询中的含义 MUST 一致，MUST NOT 在跨语言映射时降级为通用“SSH 连接异常”。输入背压和输入过大 SHALL 明确表示本次数据未被接纳，MUST NOT 被解释为会话已关闭。正常结束 SHALL 可与失败状态区分，并使 Swift 将标签呈现为已结束。重复关闭同一有效或已关闭句柄 SHALL 幂等完成并保留既有终态；某个句柄的内部失败 MUST NOT 使其他有效句柄不可用。接口 SHALL 保持同步且输入接纳不等待网络或队列腾出容量，MUST NOT 阻塞主线程。

#### Scenario: 认证失败可区分

- **WHEN** 密码错误导致连接失败
- **THEN** Swift 侧收到 `AuthFailed`，可与超时、网络错误区分处理

#### Scenario: 主机密钥问题携带指纹

- **WHEN** 发生 Mismatch 或 Reject 策略下的 Unknown
- **THEN** 错误以结构化字段携带相关指纹，UI 可直接展示

#### Scenario: 输入背压跨语言传递

- **WHEN** 本地输入队列满，Swift 发起一次 shell 写入
- **THEN** 同步返回可恢复的背压类别，整块数据未被接纳，原句柄继续有效

#### Scenario: 终态跨语言传递

- **WHEN** shell 因非零退出码、退出信号或传输错误结束
- **THEN** Swift 获得相应原因和允许的具体字段，正常退出仍可编程区分

#### Scenario: 重试后的迟到回调

- **WHEN** 旧句柄或旧建连代次的结束回调晚于新会话建立
- **THEN** 该回调仅属于旧会话，MUST NOT 覆盖新会话的状态或诊断

#### Scenario: 一个句柄内部失败不影响另一个句柄

- **GIVEN** 两个活动 shell 句柄，其中一个发生内部任务或锁恢复故障
- **WHEN** Swift 继续读写或关闭另一个句柄
- **THEN** 另一个句柄仍按自身状态正常工作，FFI 不 panic 或永久阻塞

## ADDED Requirements

### Requirement: 诊断与日志查询契约

FFI SHALL 以同步、仅内存查询提供安全的会话诊断、生命周期事件和日志记录，所有字段 MUST 使用简单值类型。事件与日志 SHALL 携带发生时间及稳定条目标识；生命周期原因、阶段和可用数值字段 MUST 跨边界保留。`log_entries(limit)` SHALL 保持最新在前的返回顺序，UI SHALL 自行适配从旧到新的显示顺序。重复查询 MUST NOT 生成新的事件标识、重新打时间戳或再次写日志。查询 MUST NOT 发起网络请求或自动重连。

#### Scenario: 重复查询日志

- **WHEN** Swift 在没有新事件时重复查询同一批日志
- **THEN** 对应条目的标识、发生时间、原因及顺序一致，文件中没有重复追加

#### Scenario: 连接释放后查询日志

- **WHEN** 连接监控记录已随连接释放而移除
- **THEN** 该连接的已记录故障仍可在未被淘汰的日志中查询，查询不重新建立连接
