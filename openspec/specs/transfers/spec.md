# transfers Specification

## Purpose
文件传输任务能力：上传与下载作为可管理任务运行，提供任务列表、实时进度条、并发队列、取消与失败重试，让大文件与批量传输可见、可控、可中断。
## Requirements
### Requirement: 传输任务列表

上传与下载 SHALL 作为任务加入统一的传输任务列表，列表 SHALL 展示方向、文件、服务器、文件大小与当前状态。

#### Scenario: 添加上传任务

- **WHEN** 用户从本地选择文件上传到远程目录
- **THEN** 任务列表新增一条上传任务，展示文件与目标服务器

#### Scenario: 添加下载任务

- **WHEN** 用户选择远程文件下载到本地目录
- **THEN** 任务列表新增一条下载任务，展示文件与目标服务器

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

### Requirement: 任务状态机

任务 SHALL 依次处于排队、传输中、已完成、失败或已取消状态，状态转换可见且唯一。

#### Scenario: 传输完成状态

- **WHEN** 一个任务完成全部字节传输
- **THEN** 该任务状态变为「已完成」

#### Scenario: 传输失败状态

- **WHEN** 传输过程中发生错误（如目标目录不可写、连接中断）
- **THEN** 该任务状态变为「失败」，并展示错误原因

### Requirement: 并发与排队

系统 SHALL 限制同时执行的传输任务数量，超出并发上限的任务 SHALL 进入排队，前一任务完成后自动开始。

#### Scenario: 超出并发上限自动排队

- **GIVEN** 并发上限为 3 且已有 3 个任务在传输
- **WHEN** 用户再启动一个传输
- **THEN** 新任务状态为「排队」，任一运行任务完成后自动开始

### Requirement: 取消任务

用户 SHALL 能取消进行中或排队中的任务；取消后 MUST 释放对应 SFTP 连接资源。

#### Scenario: 取消传输中任务

- **WHEN** 用户取消一个传输中的任务
- **THEN** 任务状态变为「已取消」，传输停止且连接资源被释放

#### Scenario: 取消排队中任务

- **WHEN** 用户取消一个排队中的任务
- **THEN** 任务状态变为「已取消」，不会被调度执行

### Requirement: 失败重试

失败或已取消任务 SHALL 允许用户重试，重试 SHALL 复用原任务 id 并重新执行，SHALL NOT 在任务列表中创建新任务条目。

#### Scenario: 重试失败任务

- **GIVEN** 一个失败的上传任务，id 为 `T1`
- **WHEN** 用户点击「重试」
- **THEN** 同一任务 `T1` 的状态重置为排队并重新调度，任务列表中不新增其他任务

#### Scenario: 重试非终态任务

- **GIVEN** 一个处于排队或传输中的任务
- **WHEN** 调用重试
- **THEN** 操作被拒绝，任务状态保持不变

### Requirement: 传输任务暂停与继续

非终态任务 SHALL 支持用户暂停与继续。暂停 SHALL 保留已传输字节数；继续 SHALL 从暂停点恢复传输。运行中任务暂停时 SHALL 保持对并发槽位的占用；排队中任务暂停时 SHALL 不提前占用并发槽位。

#### Scenario: 暂停运行中任务

- **GIVEN** 一个正在传输的大文件任务
- **WHEN** 用户点击「暂停」
- **THEN** 当前缓冲块完成后任务状态变为 `paused`，已传输字节数停止增长，该任务继续占用一个并发槽位

#### Scenario: 继续已暂停任务

- **GIVEN** 一个处于 `paused` 状态的任务
- **WHEN** 用户点击「继续」
- **THEN** 任务状态恢复为 `running`，已传输字节数继续增长

#### Scenario: 暂停排队任务

- **GIVEN** 并发上限为 3 且已有 3 个任务在传输，第 4 个任务处于 `queued`
- **WHEN** 用户对第 4 个任务点击「暂停」
- **THEN** 其状态变为 `paused`，且不会触发它去竞争并发许可证

#### Scenario: 取消暂停中任务

- **GIVEN** 一个处于 `paused` 状态的任务
- **WHEN** 用户点击「取消」
- **THEN** 任务变为 `cancelled`，释放并发槽位

#### Scenario: 重试失败任务不保留暂停

- **GIVEN** 一个失败或已取消的任务曾被暂停过
- **WHEN** 用户点击「重试」
- **THEN** 任务以 `queued` 状态重新调度，不再处于暂停

### Requirement: 传输轮询按需启动

`TransferStore` SHALL 仅在存在 running 或 queued 任务时启动轮询 Timer；任务全部完成后 SHALL 立即停止轮询。进度刷新 SHALL 仅在任务列表发生变化时触发视图更新。

#### Scenario: 无传输任务时空转

- **GIVEN** 没有进行中的传输任务
- **WHEN** App 空转
- **THEN** 不启动 100ms 轮询 Timer，不持续触发 SwiftUI 重绘

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

### Requirement: 本地目录上传拆分

选中本地目录并上传时，系统 SHALL 把该目录下的直接文件逐个加入上传队列，每个文件一个独立任务。

#### Scenario: 上传本地目录

- **GIVEN** 本地目录 `backups` 包含 `a.sql` 和 `b.sql`
- **WHEN** 选中 `backups` 并点击上传
- **THEN** 上传队列中出现 `a.sql` 和 `b.sql` 两个任务，而不是一个 `backups` 目录任务

#### Scenario: 目录中包含子目录

- **GIVEN** 本地目录 `project` 包含 `README.md` 和子目录 `src`
- **WHEN** 选中 `project` 并点击上传
- **THEN** `README.md` 加入队列，`src` 子目录被忽略

### Requirement: 任务组元数据

传输任务 SHALL 支持可选的 `groupID` 与 `groupName`。同一目录下的所有文件任务 SHALL 共享同一个 `groupID`。

#### Scenario: 目录上传生成任务组

- **GIVEN** 本地目录 `backup` 包含 `a.sql` 和 `logs/error.log`
- **WHEN** 选中 `backup` 并上传
- **THEN** 上传队列中出现两个任务：`backup/a.sql` 与 `backup/logs/error.log`，二者具有相同的 `groupID`，组名为 `backup`

#### Scenario: 独立文件无任务组

- **GIVEN** 用户多选两个普通文件 `x.txt` 与 `y.txt`
- **WHEN** 点击上传
- **THEN** 队列中出现两个任务，它们的 `groupID` 均为 nil

### Requirement: 任务组批量操作

`TransferStore` SHALL 提供 `cancelGroup` 与 `retryGroup`：前者取消组内所有非终态任务，后者重试组内所有失败任务。

#### Scenario: 批量停止目录传输

- **GIVEN** 目录 `project` 的任务组中有 5 个文件正在排队或运行
- **WHEN** 用户点击该组「停止全部」
- **THEN** 这 5 个任务全部变为 `cancelled`

#### Scenario: 批量重试目录传输

- **GIVEN** 目录 `project` 的任务组中有 3 个任务失败，2 个已完成
- **WHEN** 用户点击该组「重试失败」
- **THEN** 3 个失败任务重新进入 `queued`，2 个已完成任务保持不变

