## ADDED Requirements

### Requirement: SSH 连接生命周期日志

系统 SHALL 为终端、SFTP 和传输拥有的 SSH 连接记录生命周期日志。日志 SHALL 包含 `host:port`、运行时连接标识、非敏感所有者类型与关联标识，并区分连接成功、Channel 正常结束、用户显式关闭、Socket EOF、读写错误、keepalive 失败和用户重试。日志 MUST NOT 包含命令、终端输出、凭据、文件内容或完整私钥路径。

#### Scenario: exit 正常结束被记录

- **WHEN** 远端 shell 因用户输入 `exit` 正常结束
- **THEN** 系统记录 info 级 SSH 日志，包含连接标识、终端所有者关联和正常结束原因

#### Scenario: Socket 异常关闭被记录

- **WHEN** Socket 因 EOF、读写错误或 keepalive 连续失败而不可用
- **THEN** 系统记录 error 级 SSH 日志，包含连接标识、主机地址和非敏感失败摘要

#### Scenario: 重试建连被记录

- **WHEN** 用户对终端触发重试
- **THEN** 系统记录该标签的新建连代次和新运行时连接标识，且不记录命令或凭据

