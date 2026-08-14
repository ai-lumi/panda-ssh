## ADDED Requirements

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
