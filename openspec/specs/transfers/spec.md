# transfers Specification

## Purpose
文件传输任务能力：上传与下载作为可管理任务运行，提供任务列表、实时进度条、并发队列、取消与失败重试，让大文件与批量传输可见、可控、可中断。
## Requirements
### Requirement: 传输任务列表
上传与下载 SHALL 加入全局统一任务列表。每个任务 SHALL 展示源端、目标端、源路径、目标路径、实时速度、进度、文件大小与状态。上传的源端 SHALL 为本地、目标端 SHALL 为远程主机；下载方向 SHALL 相反。路径 SHALL 可完整查看；主机名称不可用时 SHALL 展示主机标识。页面 SHALL 保留任务组、组内任务及已有操作，包括任务的暂停、继续、取消、重试，任务组批量控制与清除已完成任务。

#### Scenario: 添加上传任务
- **WHEN** 用户上传本地文件到远程目录
- **THEN** 全局页面新增任务，源为本地、目标为对应主机，分别显示源路径和目标路径及速度、进度

#### Scenario: 添加下载任务
- **WHEN** 用户下载远程文件到本地目录
- **THEN** 源为对应主机、目标为本地，路径方向正确

#### Scenario: 多主机与空列表
- **WHEN** 不同主机存在任务或当前没有任务
- **THEN** 页面分别展示所有主机任务或空状态，且不为展示而创建连接

#### Scenario: 暂停及边界数据
- **WHEN** 任务暂停、失败、取消，或总大小为零、路径过长
- **THEN** 状态与进度不误示完成，停止传输时速度不显示为持续传输，完整路径仍可查看

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

选中本地目录并上传时，系统 SHALL 通过批量传输接口处理该目录及其子目录中的所有文件，远端目录结构 SHALL 与本地保持一致。目录上传 SHALL 作为一个批量传输任务执行，复用单个 SSH 连接，而非拆分为逐文件独立任务。仅选中多个非目录文件时，这些文件 SHALL 作为独立任务，不组成批量传输。

#### Scenario: 上传本地目录走批量路径

- **GIVEN** 本地目录 `backups` 包含 `a.sql` 和 `b.sql`
- **WHEN** 选中 `backups` 并点击上传
- **THEN** 系统创建一个批量传输任务，通过单个 SSH 连接上传 `a.sql` 和 `b.sql`，远端创建对应目录结构

#### Scenario: 目录中包含子目录

- **GIVEN** 本地目录 `project` 包含 `README.md` 和子目录 `src`
- **WHEN** 选中 `project` 并点击上传
- **THEN** 系统创建一个批量传输任务，递归上传 `README.md` 与 `src` 下所有文件，远端目录结构与本地一致

#### Scenario: 多选非目录文件仍走独立任务

- **GIVEN** 用户选中文件 `x.txt` 与 `y.txt`，未选中任何目录
- **WHEN** 点击上传
- **THEN** 队列中出现两个独立任务，不组成批量传输

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

### Requirement: 传输任务独立于源标签页

传输任务 SHALL 独立于其来源 SFTP 标签页的生命周期。关闭源 SFTP 标签页 MUST NOT 取消、暂停或标记失败该标签页创建的传输任务；任务 SHALL 继续按原有排队、并发、暂停与重试语义运行至终态。每个开始运行的单文件传输任务 SHALL 建立并独占自己的 SSH Transport，持有建连所需凭据，并在完成、失败或取消后释放连接。

#### Scenario: 关闭源标签页不取消任务

- **GIVEN** 一个由某 SFTP 标签页创建的 running 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 该任务状态保持 running，继续使用自己的连接传输，MUST NOT 变为 cancelled 或 failed

#### Scenario: 源标签页关闭后排队任务仍被调度

- **GIVEN** 一个由某 SFTP 标签页创建的 queued 传输任务，并发槽位已满
- **WHEN** 用户关闭该 SFTP 标签页，随后一个运行中任务完成释放槽位
- **THEN** 该 queued 任务被正常调度，开始时建立自己的连接

#### Scenario: 传输任务不依赖源标签页凭据

- **GIVEN** 一个由某 SFTP 标签页创建的传输任务正在运行
- **WHEN** 关闭该 SFTP 标签页并清理其会话凭据
- **THEN** 该传输任务继续正常运行，MUST NOT 因凭据缺失而失败

#### Scenario: 传输进入终态释放连接

- **WHEN** 单文件传输完成、失败或被取消
- **THEN** 系统释放该任务拥有的 SFTP Channel 与 SSH Transport，MUST NOT 影响其他任务或标签

### Requirement: 传输进度更新的渲染范围

传输任务的进度、速度、剩余时间等状态刷新 SHALL 仅作用于传输相关视图（全局传输页面、任务行、侧栏传输入口角标）；MUST NOT 触发主窗口顶部 chrome（页签栏/标题栏区域）、侧栏主机树、终端或 SFTP 标签页等无关视图的重渲染，MUST NOT 在主窗口顶部产生视觉闪烁。

#### Scenario: 上传期间主窗口顶部稳定

- **GIVEN** 一个进行中的上传任务正在持续产生进度更新
- **WHEN** 用户观察 macOS 主窗口顶部（页签栏、标题栏、红绿灯按钮）
- **THEN** 顶部区域保持视觉稳定，不出现周期性闪烁或布局抖动

#### Scenario: 传输相关视图仍实时更新

- **GIVEN** 一个进行中的上传任务
- **WHEN** 任务进度、速度或剩余时间发生变化
- **THEN** 全局传输页面中的进度条、速度与剩余时间持续平滑更新
- **AND** 侧栏传输入口角标准确反映当前活动任务数

#### Scenario: 无关视图不受进度更新影响

- **GIVEN** 工作区中已打开终端标签页和/或 SFTP 标签页，同时存在进行中的传输任务
- **WHEN** 传输任务以轮询频率持续刷新状态
- **THEN** 终端画面、SFTP 文件浏览器与侧栏主机树不因进度刷新而重绘或闪烁

#### Scenario: 独立传输窗口不受影响

- **GIVEN** 用户已打开独立传输窗口
- **WHEN** 主窗口中的上传任务产生进度更新
- **THEN** 独立传输窗口中的任务列表与进度正常更新，行为与修复前一致
