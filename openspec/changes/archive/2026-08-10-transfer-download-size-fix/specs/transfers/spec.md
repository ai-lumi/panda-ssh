## MODIFIED Requirements

### Requirement: 进度显示

每个进行中的任务 SHALL 展示进度条以及已传输字节数/百分比。下载任务 SHALL 使用从 SFTP 列表获取的远端文件大小作为总大小，进度 SHALL 从 0% 开始并按实际接收字节增长。

#### Scenario: 查看传输进度

- **GIVEN** 一个正在传输的大文件任务
- **WHEN** 用户查看任务列表
- **THEN** 该任务显示进度条与「已完成字节 / 总字节」比例

#### Scenario: 下载 300MB 文件

- **GIVEN** 远程文件大小为 300MB
- **WHEN** 开始下载
- **THEN** 任务总大小显示 300MB，进度从 0% 开始递增

#### Scenario: 下载未开始即显示 100%

- **GIVEN** 远程文件大小为 300MB
- **WHEN** 开始下载
- **THEN** 不应出现未传输即 100% 完成的情况
