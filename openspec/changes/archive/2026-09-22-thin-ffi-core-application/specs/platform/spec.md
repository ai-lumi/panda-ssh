## MODIFIED Requirements

### Requirement: 原生界面与 Rust 核心

界面 SHALL 使用 Swift 原生（SwiftUI）实现。所有平台无关业务规则、业务状态和多步骤执行流程 SHALL 位于 `crates/panda-core`；“Rust 实现”MUST NOT 被解释为可以由 `panda-ffi` 持有业务。Swift SHALL 经薄 FFI 调用核心并呈现结果，MUST NOT 重复实现连接、传输、配置、凭据、工作区逻辑状态或其他业务决策。

#### Scenario: 业务逻辑仅存在于 Rust 核心

- **WHEN** 新增或迁移一项业务能力
- **THEN** 完整用例由 `panda-core` 提供，Swift 和 FFI 只适配输入、输出和平台服务

#### Scenario: 核心原生调用方复用完整用例

- **WHEN** Rust 调用方不加载 UniFFI 或 Swift UI
- **THEN** 仍能通过核心公共接口执行与 Apple 前端相同的业务流程

### Requirement: 核心平台无关性

Rust 核心（`panda-core`）MUST NOT 依赖 Apple 平台 API、UniFFI 或 UI 框架，MUST 保持非 Apple 平台可编译与可独立复用。核心可包含异步 I/O、领域服务和状态管理；平台特有的授权文件访问、目录位置或系统生命周期接入 SHALL 由窄接口提供，接口实现不得决定业务策略。新增依赖 MUST 跨平台且许可证与项目要求兼容。

#### Scenario: 核心可在非 Apple 平台编译

- **WHEN** 使用非 Apple 目标编译 `panda-core`
- **THEN** 核心通过编译，不引用 Apple API、FFI 类型或 Swift 服务

#### Scenario: 平台权限适配不搬动业务规则

- **WHEN** iPadOS 通过系统文件授权访问用户选择的目录
- **THEN** 原生适配提供授权范围内的文件访问事实和操作，核心仍决定路径处理、任务计划、失败处置与取消行为

## ADDED Requirements

### Requirement: UI 保留呈现与原生平台交互

UI SHALL 保留布局、动画、焦点、可视区域、拖拽坐标、文件选择集、格式化及原生弹窗。业务判断所需的逻辑标识、顺序、分组和状态 SHALL 来自核心；UI 可以缓存快照和未提交编辑草稿，但不得将其作为独立业务事实来源。用户确认 SHALL 由 UI 获取并回传关联请求，是否需要确认、允许哪些动作、确认后如何执行 SHALL 由核心决定。

#### Scenario: 拖拽只提交逻辑移动

- **WHEN** 用户拖拽标签到另一个位置
- **THEN** UI 处理手势和位置命中，向核心提交标签与目标逻辑位置，按核心返回顺序呈现

#### Scenario: 切换布局不改变业务

- **WHEN** macOS 窗口变化或 iPadOS 切换常规/紧凑布局
- **THEN** 布局、可视范围和焦点由 UI 调整，核心会话、传输、分组和确认状态保持一致

#### Scenario: 原生弹窗取消

- **WHEN** 用户关闭或取消待确认弹窗
- **THEN** UI 回传该请求的取消结果，由核心决定保留状态或清理资源，UI 不自行执行隐式信任或业务回滚
