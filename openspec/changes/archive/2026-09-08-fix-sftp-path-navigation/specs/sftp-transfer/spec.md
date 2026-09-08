## ADDED Requirements

### Requirement: 浏览目录与传输路径一致

上传和下载 SHALL 使用创建任务时成功加载的源面板目录与目标面板目录，按文件名拼接完整路径。目录为 `/` 或带末尾斜杠时 MUST NOT 在连接处产生重复分隔符。中文、空格和文件名字符 MUST 原样保留。批量扫描期间切换面板目录 MUST NOT 改变已请求传输的目标目录。

#### Scenario: 切换后上传与下载

- **WHEN** 本地成功切换到 `/local/data`，远程成功切换到 `/var/data`，上传或下载 `中文 文件.txt`
- **THEN** 上传源与目标分别为 `/local/data/中文 文件.txt`、`/var/data/中文 文件.txt`；下载方向相反

#### Scenario: 根目录拼接

- **WHEN** 当前目标目录为 `/`，传输 `a.txt`
- **THEN** 目标路径为 `/a.txt`

#### Scenario: 批量扫描期间改变目录

- **GIVEN** 在远程目录 `/a` 发起上传
- **WHEN** 扫描等待期间用户切换到 `/b`
- **THEN** 此次上传全部目标仍属于 `/a`，后续新任务使用 `/b`
