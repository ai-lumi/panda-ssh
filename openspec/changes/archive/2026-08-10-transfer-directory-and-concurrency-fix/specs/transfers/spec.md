## ADDED Requirements

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
