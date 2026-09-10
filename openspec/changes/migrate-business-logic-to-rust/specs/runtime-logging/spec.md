## ADDED Requirements

### Requirement: 日志管理由后端提供 FFI

日志的环形缓冲管理、文件轮转、格式化 SHALL 由 Rust 后端实现，通过 FFI 暴露查询和写入接口。`log_entries(limit)` SHALL 返回按时间倒序的日志条目列表。`log_write(level, module, message)` SHALL 写入一条日志到环形缓冲和文件。`log_clear()` SHALL 清空环形缓冲。环形缓冲容量 SHALL 为 1000 条，超出时淘汰最旧条目。文件日志 SHALL 在达到 100MB 时轮转。

#### Scenario: 查询日志条目

- **GIVEN** 已写入 50 条日志
- **WHEN** 调用 `log_entries(20)`
- **THEN** 返回最近 20 条，按时间倒序

#### Scenario: 环形缓冲淘汰

- **GIVEN** 缓冲已满 1000 条
- **WHEN** 写入第 1001 条
- **THEN** 最旧的条目被淘汰，缓冲仍为 1000 条

#### Scenario: 文件轮转

- **GIVEN** 当前日志文件达到 100MB
- **WHEN** 写入新条目
- **THEN** 当前文件重命名为 `.1`，创建新文件继续写入

#### Scenario: 前端不做日志管理

- **WHEN** 前端渲染日志页面
- **THEN** 前端 MUST NOT 维护自己的缓冲或文件句柄，SHALL 通过 `log_entries()` 拉取
