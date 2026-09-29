## ADDED Requirements

### Requirement: 重连后 PTY 恢复

自动重连成功建立新 shell Channel 后，系统 SHALL 恢复重连前的 PTY 窗口尺寸（列数和行数）。恢复 SHALL 在新 shell 建立后立即发送 `window-change` 请求。

#### Scenario: 重连后恢复窗口尺寸

- **GIVEN** 终端标签窗口尺寸为 120×40，连接失效后自动重连
- **WHEN** 重连成功并建立新 shell
- **THEN** 系统立即发送 `window-change` 请求，将远端 PTY 设为 120×40
