# `PandaSSH.PandaCoreBackend`

源文件：`apple/PandaSSH/PandaCoreBackend.swift`

## 直接依赖

- `PandaSSH.Mock.AppBackend`：实现 UI 后端协议。
- `PandaSSH.PandaCoreBridge`：调用 Rust UniFFI 接口。
- `PandaSSH.Mock.HostEntry`、`HostGroup`、`Snippet`：UI 模型转换。
- `PandaSSH.Logging.Logger`：记录 FFI 初始化和连接错误。
- `Foundation.UUID`、`Set`：主机凭据引用与分组标识管理。

## 被依赖方

- `PandaSSH.AppModel`：加载和修改主机、分组、片段。
- `PandaSSH.Workspace.ConnectionGate`：主机密钥探测、TOFU 与失配处理。

## 跨语言边界

所有持久化、主机密钥、SSH/SFTP 规则必须经 `PandaCoreBridge` 进入 Rust；该层仅做模型适配和 UI 可见的错误状态转换。

