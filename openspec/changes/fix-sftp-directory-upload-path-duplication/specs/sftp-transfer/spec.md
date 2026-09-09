## MODIFIED Requirements

### Requirement: 目录上传保持结构

在 SFTP 界面选中本地目录并点击上传时，系统 SHALL 通过批量传输接口上传该目录及其子目录中的所有文件，远端目录结构 SHALL 与本地保持一致。当前远端目录与所选本地顶层目录名 SHALL 在目标路径中各出现一次，系统 MUST NOT 重复追加顶层目录名。

#### Scenario: 上传包含子目录的本地目录

- **GIVEN** 本地目录 `project` 包含 `README.md` 和子目录 `src/main.swift`
- **WHEN** 选中 `project` 并上传
- **THEN** 远端出现 `/current/project/README.md` 和 `/current/project/src/main.swift`

#### Scenario: 上传中文命名的本地目录

- **GIVEN** 当前远端目录为 `/share/CACHEDEV1_DATA/homes/lwq`，本地目录 `报销-20260706` 包含文件 `上海到广州机票-20260706-发票-保险.pdf`
- **WHEN** 选中该本地目录并上传
- **THEN** 文件出现在 `/share/CACHEDEV1_DATA/homes/lwq/报销-20260706/上海到广州机票-20260706-发票-保险.pdf`，且目标路径不包含连续两层 `报销-20260706`
