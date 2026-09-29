## ADDED Requirements

### Requirement: 重连期间所有权保持

终端标签的自动重连 SHALL 为该标签建立新 Transport，MUST NOT 复用其他所有者的连接。重连期间旧 Socket SHALL 已释放，同主机其他标签页的连接状态 SHALL 不受影响。

#### Scenario: 重连不影响其他标签

- **GIVEN** 同一主机有两个终端标签，标签 A 开始自动重连
- **WHEN** 标签 A 正在重连过程中
- **THEN** 标签 B 的连接保持正常，SHALL NOT 被标签 A 的重连流程影响
