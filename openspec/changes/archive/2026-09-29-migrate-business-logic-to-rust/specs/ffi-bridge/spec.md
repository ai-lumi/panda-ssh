## ADDED Requirements

### Requirement: 新增业务逻辑 FFI 导出

`panda-ffi` SHALL 新增以下导出函数，供前端直接调用已下沉到 Rust 的业务逻辑：

| 函数 | 模块 | 说明 |
|------|------|------|
| `search_hosts(query)` | hosts | 主机模糊搜索 |
| `group_path(group_id)` | groups | 分组层级路径 |
| `sidebar_tree()` | groups | 侧栏树组装 |
| `credential_resolve(host_id)` | credentials | 凭据解析 |
| `connection_failure_classify(error_code)` | error | 错误分类 |
| `transfer_groups()` | transfers | 任务分组聚合 |
| `transfer_register_observer()` | transfers | 推送回调注册 |
| `workspace_open_tab()` | workspace | 打开标签页 |
| `workspace_close_tab()` | workspace | 关闭标签页 |
| `workspace_tab_list()` | workspace | 标签页列表（含去重标题） |
| `workspace_host_connection_status()` | workspace | 主机连接状态聚合 |
| `terminal_session_open()` | workspace | 打开终端会话 |
| `terminal_session_retry()` | workspace | 重试终端连接 |
| `terminal_session_phase()` | workspace | 查询会话阶段 |
| `preconnect_evaluate()` | preconnect | 连接前评估 |
| `preconnect_tofu_probe()` | preconnect | TOFU 密钥探测 |
| `preconnect_tofu_confirm()` | preconnect | TOFU 信任确认 |
| `config_export()` | config_archive | 配置导出 |
| `config_import()` | config_archive | 配置导入 |
| `log_entries()` | logger | 日志条目查询 |
| `log_write()` | logger | 写入日志 |
| `log_clear()` | logger | 清空日志 |

#### Scenario: 新增导出不破坏现有调用

- **GIVEN** 现有 FFI 函数已在使用中
- **WHEN** 新增上述导出函数
- **THEN** 现有函数的签名、语义和返回值 MUST NOT 改变

#### Scenario: 新增导出使用简单值类型

- **WHEN** 新增函数定义 Record/Enum 类型
- **THEN** 只使用 String、整数、Optional、Vec 等 uniffi 支持的简单值类型，不包含平台特有类型
