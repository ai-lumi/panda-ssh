## ADDED Requirements

### Requirement: 连接遥测 FFI 查询

FFI 层 SHALL 导出同步的连接遥测快照查询与针对指定连接标识的健康检查接口。导出记录 MUST 分别提供传输 I/O 状态、SSH keepalive 状态和通道状态，且使用 FFI 友好的简单值类型；平台可用的内核 TCP 状态为可选字段。MUST NOT 包含凭据、终端内容、命令文本或文件内容。健康检查的异步工作 SHALL 在既有全局 tokio runtime 上执行。

#### Scenario: Swift 查询连接快照
- **WHEN** Swift 在非主线程调用连接遥测快照查询接口
- **THEN** 接口返回当前内存快照或空列表，且不阻塞主线程、不建立新 SSH 连接

#### Scenario: 不存在的连接标识
- **WHEN** Swift 对已释放或不存在的连接标识调用健康检查接口
- **THEN** 接口返回可区分的未找到结果或错误，且 MUST NOT 创建新连接
