## ADDED Requirements

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
