# ssh-connection Spec Delta

## MODIFIED Requirements

### Requirement: 命令执行

系统 SHALL 支持在会话上执行单条命令并收集结果：stdout、stderr、退出码。命令执行 MUST 有超时（默认 60 秒），超时 MUST 返回 `Timeout` 错误并终止等待，SHALL NOT 无限阻塞调用方。

#### Scenario: 执行结果完整

- **WHEN** 执行一条向 stdout/stderr 输出并以非零码退出的命令
- **THEN** 返回的 `ExecOutput` 包含两路输出；服务器报告退出码时 MUST 原样返回

#### Scenario: 命令超时

- **WHEN** 执行的命令在超时时间内不结束
- **THEN** 返回 `Timeout` 错误，调用方线程不被永久阻塞
