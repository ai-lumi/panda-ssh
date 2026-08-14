## ADDED Requirements

### Requirement: 启动传输任务

`start_transfer` SHALL 接受 `size` 参数；对于下载任务 SHALL 使用该值作为总大小；对于上传任务，当 `size` 为 0 时 SHALL 从本地文件计算，否则 SHALL 使用传入值。

#### Scenario: 下载任务带大小启动

- **GIVEN** 调用 `start_transfer(direction=Download, size=300_000_000, ...)`
- **WHEN** 任务入队
- **THEN** 任务总大小为 300_000_000 字节

#### Scenario: 上传任务未传大小

- **GIVEN** 调用 `start_transfer(direction=Upload, size=0, local_path="/local/f.bin", ...)`
- **WHEN** 任务入队
- **THEN** 任务总大小等于 `/local/f.bin` 的实际大小
