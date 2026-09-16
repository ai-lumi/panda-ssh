## ADDED Requirements

### Requirement: FFI 模块边界与覆盖率责任

FFI 实现 SHALL 将无状态纯值适配器与拥有业务状态、资源生命周期、持久化副作用或错误策略的实现分离。只有纯值适配器模块 MAY 被覆盖率文件级排除；会话、传输、TOFU、凭据、日志、遥测、工作区和终端状态机 MUST 继续计入 Rust lines 与 regions 覆盖率门禁。模块拆分 MUST NOT 改变既有 UniFFI 导出名称、参数、返回类型或同步调用外观。

#### Scenario: 纯适配器可独立审查

- **WHEN** 覆盖率配置排除 FFI 纯适配器模块
- **THEN** 被排除模块仅包含无状态值转换或 core 函数转发，且不访问 runtime、store、会话/任务注册表、网络或文件系统

#### Scenario: 业务 FFI 仍受门禁约束

- **WHEN** 运行 Rust 覆盖率门禁
- **THEN** 会话句柄、传输调度、TOFU、持久化、日志、遥测、工作区和终端状态机所在模块均被统计，且 lines 与 regions MUST 分别不低于 95%

#### Scenario: 拆分保持 Swift 契约

- **WHEN** FFI 内部模块被拆分后生成 Swift 绑定
- **THEN** 既有 Swift 调用可继续以相同导出名称、参数和返回类型构建及运行
