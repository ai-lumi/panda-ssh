# sftp-transfer Specification

## Purpose

基于 russh-sftp 的远程文件操作：目录列举、上传、下载、删除、建目录。SFTP 会话从既有 SSH 会话上开 channel 建立，不单独认证。
## Requirements
### Requirement: 目录列举

系统 SHALL 支持列举远程目录，返回条目包含：名称、完整路径、是否目录、字节大小、修改时间（可选）。

#### Scenario: 列举结果字段完整

- **WHEN** 列举一个含文件与子目录的远程目录
- **THEN** 每个条目都带有名称、路径、类型与大小

### Requirement: 文件传输

系统 SHALL 支持上传与下载；上传 MUST 支持进度回调（已传字节 / 总字节）。当源路径或目标路径为目录时，系统 SHALL 按批量传输规则递归处理子目录与文件。当调用方传入多个源路径时，系统 SHALL 将其作为一个批量传输任务依次处理，并持续上报整个批次的聚合进度回调。

#### Scenario: 上传目录触发递归传输

- **GIVEN** 上传源路径为本地目录
- **WHEN** 系统检测到源路径是目录
- **THEN** 系统递归上传该目录及其所有子目录、文件到远程目标目录

#### Scenario: 下载目录触发递归传输

- **GIVEN** 下载源路径为远程目录
- **WHEN** 系统检测到源路径是目录
- **THEN** 系统递归下载该目录及其所有子目录、文件到本地目标目录

#### Scenario: 多选源路径作为批量任务处理

- **GIVEN** 调用方传入多个本地源路径（文件或目录）准备上传
- **WHEN** 系统接收到该批量请求
- **THEN** 系统创建一个批量传输任务，依次处理每个源路径，并聚合显示进度

#### Scenario: 上传带进度

- **WHEN** 上传一个本地文件并提供进度回调
- **THEN** 回调按字节递增被调用，完成后远程文件内容与本地一致

#### Scenario: 下载

- **WHEN** 下载一个远程文件到本地路径
- **THEN** 本地文件内容与远程一致

#### Scenario: 批量传输持续上报进度

- **GIVEN** 一个批量任务正在上传，包含多个文件与目录
- **WHEN** 系统传输每个项目
- **THEN** 进度回调持续上报当前已传总字节与总字节数

### Requirement: 文件传输进度包含速度指标

文件传输的进度展示 SHALL 包含实时速度与总速度信息，使调用方（UI）能够向用户呈现当前传输速率。速度信息可由调用方根据进度回调的时间戳与已传字节数推导，不强制要求核心库额外暴露速度字段。

#### Scenario: 上传进度可推导出速度

- **GIVEN** 上传任务持续接收进度回调（已传字节 + 时间戳）
- **WHEN** UI 根据回调计算速度
- **THEN** 可得到实时速度与总速度，并在面板中展示

#### Scenario: 下载进度可推导出速度

- **GIVEN** 下载任务持续接收进度回调（已传字节 + 时间戳）
- **WHEN** UI 根据回调计算速度
- **THEN** 可得到实时速度与总速度，并在面板中展示

### Requirement: 远程文件管理

系统 SHALL 支持删除文件、删除目录、创建目录。

#### Scenario: 创建再删除

- **WHEN** 创建远程目录后将其删除
- **THEN** 两次操作均成功且目录不再存在

### Requirement: SFTP 远程面板根目录由运行时解析

SFTP 双栏 SHALL 使用服务器返回的会话初始工作目录作为远程面板根目录；解析失败时 SHALL 回退到 `/`。

#### Scenario: 连接到非标准 home 路径的服务器

- **GIVEN** 服务器实际 home 目录为 `/share/CACHEDEV1_DATA/homes/lwq`
- **WHEN** 打开该主机的 SFTP 标签页
- **THEN** 远程面板根目录显示 `/share/CACHEDEV1_DATA/homes/lwq`

### Requirement: 目标文件存在性检测

上传或下载文件前，系统 SHALL 检测目标路径是否已存在文件。若目标已存在文件，系统 SHALL 暂停传输并向调用方返回覆盖确认请求，而不是直接覆盖。

#### Scenario: 上传时远程目标已存在

- **GIVEN** 本地文件 `/local/readme.txt` 准备上传到远程 `/remote/readme.txt`
- **WHEN** 远程 `/remote/readme.txt` 已存在
- **THEN** 传输不执行覆盖，而是返回覆盖确认请求，包含源文件与目标文件的大小及最后修改时间

#### Scenario: 下载时本地目标已存在

- **GIVEN** 远程文件 `/remote/readme.txt` 准备下载到本地 `/local/readme.txt`
- **WHEN** 本地 `/local/readme.txt` 已存在
- **THEN** 传输不执行覆盖，而是返回覆盖确认请求，包含源文件与目标文件的大小及最后修改时间

#### Scenario: 目标不存在时直接传输

- **GIVEN** 上传或下载的目标路径不存在文件
- **WHEN** 发起传输
- **THEN** 系统直接执行传输，不弹出覆盖确认

### Requirement: 覆盖确认元数据

覆盖确认请求 MUST 包含源文件与目标文件的以下元数据：字节大小（size）与最后修改时间（mtime）。时间 SHOULD 以 Unix 时间戳（秒）形式传递，UI 层负责本地化展示。

#### Scenario: 元数据字段完整

- **WHEN** 系统返回覆盖确认请求
- **THEN** 请求中同时包含源文件大小、源文件修改时间、目标文件大小、目标文件修改时间

### Requirement: 覆盖决策执行

系统 SHALL 根据调用方最终决策执行以下动作之一：覆盖目标、跳过本次传输。未来可扩展「保留两者」（自动重命名）。

#### Scenario: 用户选择覆盖

- **GIVEN** 调用方收到覆盖确认请求并决定覆盖
- **WHEN** 调用方继续传输
- **THEN** 系统执行覆盖写入

#### Scenario: 用户选择跳过

- **GIVEN** 调用方收到覆盖确认请求并决定跳过
- **WHEN** 调用方取消该传输
- **THEN** 系统不写入任何文件，且该传输被视为正常取消，不返回错误

### Requirement: 目录上传保持结构

在 SFTP 界面选中本地目录并点击上传时，系统 SHALL 通过批量传输接口上传该目录及其子目录中的所有文件，远端目录结构 SHALL 与本地保持一致。

#### Scenario: 上传包含子目录的本地目录

- **GIVEN** 本地目录 `project` 包含 `README.md` 和子目录 `src/main.swift`
- **WHEN** 选中 `project` 并上传
- **THEN** 远端出现 `/current/project/README.md` 和 `/current/project/src/main.swift`

### Requirement: 目录下载保持结构

在 SFTP 界面选中远程目录并点击下载时，系统 SHALL 通过批量传输接口下载该目录及其子目录中的所有文件，本地目录结构 SHALL 与远端保持一致。

#### Scenario: 下载包含子目录的远程目录

- **GIVEN** 远程目录 `backup` 包含 `a.sql` 和子目录 `logs/error.log`
- **WHEN** 选中 `backup` 并下载
- **THEN** 本地出现 `/current/backup/a.sql` 和 `/current/backup/logs/error.log`

