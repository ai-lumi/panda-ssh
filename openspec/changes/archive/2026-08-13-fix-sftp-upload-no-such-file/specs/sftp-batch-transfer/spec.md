## ADDED Requirements

### Requirement: 批量上传远端目录创建具备递归语义

批量上传过程中，系统为本地目录在远端创建对应目录结构时，SHALL 递归创建所有缺失的父目录（等价于 `mkdir -p`）。若远端目标目录已存在，SHALL 视为成功，不再记录错误。该行为 SHALL 与批量下载时本地目录创建语义保持一致。

#### Scenario: 上传目录到不存在的远端父目录

- **GIVEN** 本地目录 `project` 包含文件 `README.md`，用户将其上传到远端 `/remote/newdir`
- **WHEN** `/remote/newdir` 在远端不存在
- **THEN** 系统创建 `/remote/newdir/project` 并将 `README.md` 上传至 `/remote/newdir/project/README.md`，整个批量任务成功完成

#### Scenario: 上传目录时远端目录已存在

- **GIVEN** 本地目录 `project` 包含文件 `README.md`，远端已存在 `/current/project`
- **WHEN** 用户将其上传到远端 `/current`
- **THEN** 系统视 `/current/project` 已存在为正常，继续上传 `README.md` 并完成任务，不提示错误

#### Scenario: 上传嵌套目录结构到远端

- **GIVEN** 本地目录 `project/src` 包含文件 `main.swift`
- **WHEN** 用户将 `project` 上传到远端 `/remote`
- **THEN** 系统依次创建 `/remote/project` 与 `/remote/project/src`，并将 `main.swift` 上传至 `/remote/project/src/main.swift`

### Requirement: 批量传输错误信息包含源路径与目标路径

批量传输中某个项目失败时，系统记录的错误信息 SHALL 同时包含本地源路径与远端目标路径，使用户能够定位具体失败项。错误信息 MAY 包含底层原因，但 MUST 优先暴露路径信息。

#### Scenario: 批量上传某个远端目录创建失败

- **GIVEN** 批量上传包含本地目录 `project`，因远端权限等原因无法在目标位置创建目录
- **WHEN** 系统记录该项错误
- **THEN** 错误信息 SHALL 包含本地源路径 `project` 与远端目标路径 `/remote/project`

#### Scenario: 批量上传某个文件失败

- **GIVEN** 批量上传包含本地文件 `project/src/main.swift`
- **WHEN** 该文件上传失败
- **THEN** 错误信息 SHALL 包含本地源路径 `project/src/main.swift` 与远端目标路径 `/remote/project/src/main.swift`
