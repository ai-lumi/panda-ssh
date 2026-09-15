## ADDED Requirements

### Requirement: 批量传输 FFI 层异步非阻塞

批量传输的目录扫描与冲突回调 MUST NOT 阻塞 tokio worker 线程。扫描操作 SHALL 通过 `runtime().spawn()` 提交异步任务并使用 oneshot channel 获取结果，不得使用 `runtime().block_on()`。冲突回调 SHALL 使用 `tokio::sync::oneshot` + `tokio::time::timeout` 实现异步等待，不得使用 `std::sync::mpsc::Receiver::recv_timeout()` 等同步阻塞原语。

#### Scenario: 目录扫描不占住 worker 线程

- **GIVEN** 批量传输需要扫描本地或远程目录
- **WHEN** 扫描操作执行期间
- **THEN** tokio worker 线程不被同步阻塞，其他异步任务（包括正在进行的传输）可正常调度执行

#### Scenario: 冲突回调异步等待

- **GIVEN** 批量传输遇到目标文件已存在，需要等待用户决策
- **WHEN** 冲突回调等待用户响应期间
- **THEN** 等待以异步方式实现（`tokio::time::timeout` + `tokio::sync::oneshot`），不阻塞 tokio worker 线程

#### Scenario: 慢网速下 UI 保持响应

- **GIVEN** 网络延迟高，单次 SSH 建连耗时数秒
- **WHEN** 用户发起包含大量文件的目录批量上传
- **THEN** UI 主线程不被阻塞，进度面板可持续更新，用户可执行取消等操作
