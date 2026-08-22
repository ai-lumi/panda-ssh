## MODIFIED Requirements

### Requirement: 同步调用语义

所有导出函数对调用方 MUST 表现为同步调用；内部异步逻辑 SHALL 在懒初始化的全局 tokio runtime 上执行。

**变更说明：** 增加调用方调度约束——同步调用 MUST NOT 阻塞主线程；阻塞型调用（SSH/SFTP 连接、网络往返）SHALL 由调用方在非主线程执行，并 SHALL 支持多个连接并行建立。

#### Scenario: 从任意线程调用

- **WHEN** Swift 侧从非 tokio 线程调用导出函数
- **THEN** 正常返回结果或错误，不发生 block_on 嵌套 panic

#### Scenario: 连接建立不阻塞主线程

- **WHEN** 用户打开 SSH 或 SFTP 标签，连接握手（DNS/网络/认证）耗时较长
- **THEN** 主线程不被占用，页面可正常交互（滚动、切换标签、打开其他连接），连接结果稍后回传

#### Scenario: 多个连接并行建立

- **WHEN** 用户先后为多台主机打开连接标签，网络延迟较高
- **THEN** 各主机连接并行握手，互不排队；任一连接完成即可呈现，无需等待其他连接