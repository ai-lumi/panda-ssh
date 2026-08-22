## MODIFIED Requirements

### Requirement: 终端数据流

系统 SHALL 支持 PTY shell 的双向数据流。客户端写入的输入字节 MUST 通过 SSH 通道发送到服务端 PTY；服务端 PTY 输出 MUST 被客户端读取并缓存，供上层终端视图消费。终端缓冲区大小 MUST 在终端初始化时从用户配置读取并应用；若用户未配置或配置无效，则使用默认值 10000 行。

#### Scenario: 用户输入被正确转发

- **WHEN** 用户在终端中输入字符
- **THEN** 输入字节通过 SSH 通道发送到服务端 PTY

#### Scenario: 服务端输出被正确读取

- **WHEN** 服务端 shell 产生输出（包含 ANSI 转义码）
- **THEN** 输出字节被客户端读取并传递给终端视图渲染

#### Scenario: 空读取不阻塞

- **WHEN** 当前没有服务端输出
- **THEN** 读取操作立即返回空数据，SHALL NOT 阻塞调用线程

#### Scenario: 终端使用配置的缓冲区大小初始化

- **GIVEN** 用户在设置中将缓冲区行数设为 25000
- **WHEN** 打开新的终端标签页
- **THEN** 该终端的回滚缓冲区上限为 25000 行
