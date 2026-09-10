## MODIFIED Requirements

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
