## ADDED Requirements

### Requirement: 传输完成后自动刷新

上传完成后，若目标路径位于当前远程面板目录，SFTP 远程面板 SHALL 自动刷新；下载完成后，若目标路径位于当前本地面板目录，本地面板 SHALL 自动刷新。

#### Scenario: 上传完成后刷新远程面板

- **GIVEN** 当前远程面板位于 `/share/homes/lwq/ssh-test`
- **WHEN** 上传 `deploy.tar.gz` 到该目录且任务完成
- **THEN** 远程面板自动重新列出目录，`deploy.tar.gz` 出现在列表中

#### Scenario: 下载完成后刷新本地面板

- **GIVEN** 当前本地面板位于 `/tmp/panda-ssh-manual-test`
- **WHEN** 从远程下载 `app.log` 到该目录且任务完成
- **THEN** 本地面板自动重新列出目录，`app.log` 出现在列表中

### Requirement: 手动刷新当前目录

SFTP 双栏顶部 SHALL 提供手动刷新按钮，点击后刷新当前面板目录内容。

#### Scenario: 点击刷新按钮

- **GIVEN** 当前本地面板显示旧文件列表
- **WHEN** 点击顶部刷新按钮
- **THEN** 本地面板重新加载并显示最新文件列表
