## MODIFIED Requirements

### Requirement: 初始化

`init_store(config_dir)` 设置当前进程的配置目录；未初始化时调用其他接口 MUST 返回 `NotInitialized`。App 生命周期内只调用一次；测试场景允许重新初始化以切换临时目录。

#### Scenario: 未初始化调用

- **WHEN** 未调用 `init_store` 直接调用 `list_hosts`
- **THEN** 返回 `NotInitialized` 错误

#### Scenario: 集成测试切换临时目录

- **GIVEN** 进程内已调用过 `init_store`
- **WHEN** 在同进程中再次调用 `init_store` 指向新的临时目录
- **THEN** 后续 store 操作使用新的临时目录
