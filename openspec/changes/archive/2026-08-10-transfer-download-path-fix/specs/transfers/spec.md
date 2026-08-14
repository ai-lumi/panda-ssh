## ADDED Requirements

### Requirement: 传输任务路径解析

`TransferStore.add` SHALL 根据 `direction` 将 `source`/`destination` 正确解析为 `localPath`/`remotePath`：上传时 source=本地、destination=远程；下载时 source=远程、destination=本地。

#### Scenario: 上传文件路径解析

- **GIVEN** 调用 `add(direction: .upload, source: "/local/f.bin", destination: "/remote/f.bin")`
- **WHEN** 任务入队
- **THEN** FFI 收到 `localPath = "/local/f.bin"`, `remotePath = "/remote/f.bin"`

#### Scenario: 下载文件路径解析

- **GIVEN** 调用 `add(direction: .download, source: "/remote/f.bin", destination: "/local/f.bin")`
- **WHEN** 任务入队
- **THEN** FFI 收到 `localPath = "/local/f.bin"`, `remotePath = "/remote/f.bin"`
