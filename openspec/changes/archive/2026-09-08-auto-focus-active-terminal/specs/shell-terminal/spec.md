## MODIFIED Requirements

### Requirement: 终端键盘焦点

系统 SHALL 在新 SSH 终端视图完成挂载后，以及用户切换到已打开的 SSH 终端标签页后，将键盘焦点置于该活动终端，使用户可直接输入。为保持 SSH shell 存活而留在视图树中的非活动终端 MUST NOT 请求或抢占键盘焦点。

#### Scenario: 打开新终端

- **WHEN** 用户打开一个 SSH 终端且连接进入 shell 状态
- **THEN** 新终端视图成为键盘输入目标，无需用户额外点击

#### Scenario: 切回已打开终端

- **GIVEN** 两个已打开的 SSH 终端标签页均保留在视图树中
- **WHEN** 用户切换到其中一个终端标签页
- **THEN** 被切换到的终端成为键盘输入目标
- **AND** 隐藏终端不得抢占该焦点
