# sftp-batch-transfer Specification

## Purpose
定义 SFTP 批量（多选文件/目录）上传与下载的行为规则：递归遍历所有选中的源项目、在远程或本地创建对应目录结构、逐个文件传输、聚合总进度、处理目标存在性冲突，并允许用户取消或重试整个批量传输任务。

## Requirements

### Requirement: 批量上传支持多选文件与目录

系统 SHALL 支持在 SFTP 本地文件栏中同时选中多个文件和/或多个目录项。用户点击上传时，系统 SHALL 将所有选中项作为一批源路径交给批量上传接口。选中目录时 SHALL 递归上传其所有子目录与文件；选中文件时 SHALL 直接上传到当前远程目录。每个选中的顶层目录 SHALL 成为一个任务组，组内每个文件为独立任务；仅选中多个文件时，这些文件 SHALL 作为独立任务，不组成任务组。

#### Scenario: 多选文件与目录一起上传

- **GIVEN** 用户选中本地文件 `README.md` 与本地目录 `src`（含 `main.swift`）
- **WHEN** 用户将其批量上传到远程 `/remote/project`
- **THEN** 远程创建 `/remote/project/README.md` 与 `/remote/project/src/main.swift`，`src` 作为任务组、`README.md` 作为独立任务

#### Scenario: 上传空目录

- **GIVEN** 批量选中的某个本地目录为空
- **WHEN** 系统上传该批量选择
- **THEN** 远程为该空目录创建对应目录结构，不报错

#### Scenario: 本地栏仅选中单个目录上传

- **GIVEN** 用户在本地栏选中单个目录 `Documents`
- **WHEN** 用户点击上传
- **THEN** 系统为 `Documents` 创建一个任务组，组内每个文件为独立任务

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

### Requirement: 批量下载支持多选远程文件与目录

系统 SHALL 支持在 SFTP 远程文件栏中同时选中多个文件和/或多个目录项。用户点击下载时，系统 SHALL 将所有选中项作为一批源路径交给批量下载接口。选中目录时 SHALL 递归下载其所有子目录与文件；选中文件时 SHALL 直接下载到当前本地目录。每个选中的顶层目录 SHALL 成为一个任务组，组内每个文件为独立任务；仅选中多个文件时，这些文件 SHALL 作为独立任务，不组成任务组。

#### Scenario: 多选远程文件与目录一起下载

- **GIVEN** 用户选中远程文件 `app.log` 与远程目录 `archive`（含 `old.log`）
- **WHEN** 用户将其批量下载到本地 `/local/logs`
- **THEN** 本地创建 `/local/logs/app.log` 与 `/local/logs/archive/old.log`，`archive` 作为任务组、`app.log` 作为独立任务

#### Scenario: 远程栏仅选中单个目录下载

- **GIVEN** 用户在远程栏选中单个目录 `backup`
- **WHEN** 用户点击下载
- **THEN** 系统为 `backup` 创建一个任务组，组内每个文件为独立任务

### Requirement: 选中目录作为任务组、选中多个非目录文件不作为任务组

当用户选中一个或多个目录时，每个选中的顶层目录 SHALL 成为一个任务组；该目录下的每个文件（含子目录中的文件） SHALL 作为该任务组内的独立任务。子目录本身 SHALL 不作为任务组。当用户仅选中多个文件（未选中任何目录）时，这些文件 SHALL 作为独立任务，不组成任务组。

#### Scenario: 多选多个目录产生多个任务组

- **GIVEN** 用户同时选中目录 `dirA` 与 `dirB`
- **WHEN** 用户点击上传
- **THEN** 系统创建两个任务组 `dirA` 与 `dirB`，每个组内包含对应目录下递归展开的文件任务

#### Scenario: 多选多个非目录文件不产生任务组

- **GIVEN** 用户同时选中文件 `a.txt`、`b.txt`、`c.txt`，未选中任何目录
- **WHEN** 用户点击下载
- **THEN** 系统创建三个独立任务，不生成任务组

#### Scenario: 目录任务组内部子目录不成为子任务组

- **GIVEN** 用户选中目录 `project`，其下包含 `src/main.swift`
- **WHEN** 用户点击上传
- **THEN** 仅生成一个任务组 `project`，`src/main.swift` 是该组内的独立任务，`src` 本身不是任务组

### Requirement: 任务组支持批量控制与独立控制

对于每个任务组，系统 SHALL 支持对整个组执行停止、继续、重试；同时 SHALL 允许对组内每个独立任务单独执行停止、继续、重试。对任务组的控制操作 SHALL 作用于组内所有任务；对单个任务的控制操作 SHALL 只影响该任务。

#### Scenario: 批量停止任务组

- **GIVEN** 任务组 `project` 内有 3 个文件任务正在传输
- **WHEN** 用户点击任务组的停止按钮
- **THEN** 该任务组内所有任务均被停止

#### Scenario: 单独停止任务组内某个文件

- **GIVEN** 任务组 `project` 内有 3 个文件任务正在传输
- **WHEN** 用户点击其中 1 个文件任务的停止按钮
- **THEN** 仅该文件任务被停止，其余 2 个继续传输

#### Scenario: 批量重试任务组

- **GIVEN** 任务组 `project` 内有 2 个任务失败、1 个任务成功
- **WHEN** 用户点击任务组的重试按钮
- **THEN** 2 个失败任务被重试，已成功任务保持不变

### Requirement: 批量传输聚合总进度

批量传输任务 SHALL 报告整体进度：已传字节总数、总字节数、实时速度、总速度与预估剩余时间。对于任务组，系统 SHALL 同时展示组级聚合进度与组内每个独立任务的进度。总字节数 SHALL 在所有选中项目遍历完成后确定；若无法预先获取全部文件大小，SHALL 在遍历过程中动态更新总字节数。

#### Scenario: 批量上传时显示总进度

- **GIVEN** 用户选中多个文件与目录，总大小 100 MB，正在上传
- **WHEN** 用户查看传输面板
- **THEN** 进度条与速度标签反映整个批量选择的聚合进度，而非单个文件

#### Scenario: 任务组显示组内文件进度

- **GIVEN** 任务组 `project` 包含 3 个文件任务
- **WHEN** 用户展开该任务组
- **THEN** 每个文件任务的独立进度、状态、速度均可见

### Requirement: SFTP 文件栏区分进入目录与选中目录

SFTP 本地与远程文件栏 SHALL 区分「进入目录」与「选中目录」两种操作：单击目录名或双击目录 SHALL 进入该目录；多选模式或显式选择操作 SHALL 可以将目录作为传输源选中。未进入多选模式时，单击任意条目（文件或目录）SHALL 高亮该条目并取消其他条目的高亮；选中单个目录后点击上传/下载 SHALL 走批量传输流程。

#### Scenario: 单击目录高亮并可用于批量上传

- **GIVEN** 用户在本地栏单击目录 `Documents`
- **WHEN** 用户点击上传按钮
- **THEN** 系统为 `Documents` 创建任务组并开始批量上传，而不是进入该目录

#### Scenario: 单选模式下单击切换高亮互斥

- **GIVEN** 用户在本地栏先单击选中文件 `notes.md`
- **WHEN** 用户再单击目录 `Downloads`
- **THEN** `Downloads` 高亮，`notes.md` 不再高亮

#### Scenario: 双击目录仍进入目录

- **GIVEN** 用户在本地栏双击目录 `Documents`
- **WHEN** 系统响应该双击
- **THEN** 文件栏切换到 `Documents` 内部，不创建传输任务

### Requirement: 多选模式显示复选框

SFTP 本地与远程文件栏进入多选模式后，每个可选项（文件与目录）的行首 SHALL 显示复选框。复选框的勾选状态 SHALL 与该项的选中状态保持一致；点击复选框或点击整行 SHALL 切换该项的选中状态。

#### Scenario: 多选模式下文件与目录均显示复选框

- **GIVEN** 用户在本地栏进入多选模式，当前目录包含文件 `a.txt` 与目录 `dir`
- **WHEN** 用户查看文件列表
- **THEN** `a.txt` 与 `dir` 每行左侧均显示复选框

#### Scenario: 点击复选框切换选中

- **GIVEN** 用户在本地栏进入多选模式
- **WHEN** 用户点击文件 `a.txt` 行的复选框
- **THEN** `a.txt` 被加入多选集合；再次点击同一复选框，`a.txt` 从集合中移除

### Requirement: macOS 端支持 Command 键多选

在 macOS 端，SFTP 文件栏 SHALL 支持按住 `⌘`（Command）键单击条目进行多选：按住 `⌘` 单击未选中条目 SHALL 将其追加到当前选中集合；按住 `⌘` 单击已选中条目 SHALL 将其从选中集合移除；未按住 `⌘` 的单击 SHALL 仅选中该条目并取消其他所有条目选中。

#### Scenario: Command 键追加选中

- **GIVEN** 用户在 macOS 端本地栏已单击选中 `a.txt`
- **WHEN** 用户按住 `⌘` 键再单击 `b.txt`
- **THEN** `a.txt` 与 `b.txt` 同时被选中

#### Scenario: Command 键取消单个选中

- **GIVEN** 用户在 macOS 端本地栏已选中 `a.txt` 与 `b.txt`
- **WHEN** 用户按住 `⌘` 键再次单击 `a.txt`
- **THEN** 只有 `b.txt` 保持选中

#### Scenario: 未按 Command 键单击重置选中

- **GIVEN** 用户在 macOS 端本地栏已用 `⌘` 键多选 `a.txt`、`b.txt`
- **WHEN** 用户未按任何修饰键单击 `c.txt`
- **THEN** 只有 `c.txt` 被选中，`a.txt` 与 `b.txt` 取消选中

### Requirement: macOS 与 iPadOS（接鼠标）支持框选多选

在 macOS 端以及 iPadOS 接入鼠标/触控板时，SFTP 文件栏 SHALL 支持按住鼠标左键（或触控板单指按下）拖拽形成矩形选区：选区矩形覆盖到的所有条目 SHALL 进入选中状态；拖拽开始时若未按住 Command 键，SHALL 先清空已有选中集合；拖拽开始时若按住 Command 键，SHALL 在保留已有选中的基础上追加框选条目。

#### Scenario: 鼠标框选多个条目

- **GIVEN** 用户在 macOS 端本地栏看到文件 `a.txt`、`b.txt`、`c.txt`
- **WHEN** 用户从 `a.txt` 左上角按住鼠标左键拖拽到 `c.txt` 右下角
- **THEN** `a.txt`、`b.txt`、`c.txt` 全部进入选中状态

#### Scenario: Command 键下框选追加

- **GIVEN** 用户在 macOS 端本地栏已用 `⌘` 键选中 `a.txt`
- **WHEN** 用户按住 `⌘` 键并框选 `b.txt` 与 `c.txt`
- **THEN** `a.txt`、`b.txt`、`c.txt` 同时被选中

#### Scenario: iPadOS 接鼠标时框选可用

- **GIVEN** 用户在 iPadOS 端接入蓝牙鼠标并打开 SFTP 本地栏
- **WHEN** 用户按住鼠标左键拖拽形成覆盖多个条目的选区
- **THEN** 被覆盖条目进入选中状态

### Requirement: 批量传输中的文件冲突复用单文件覆盖确认

批量传输中遇到单个目标文件已存在时，系统 SHALL 暂停该文件的写入并返回覆盖确认请求。请求 SHALL 包含源文件与目标文件的大小及最后修改时间，与单文件传输保持一致。

#### Scenario: 批量上传时远程目标文件已存在

- **GIVEN** 批量上传本地多个项目到远程，其中某个文件在远程已存在
- **WHEN** 系统检测到该目标文件
- **THEN** 传输暂停于该文件，返回覆盖确认请求，用户可选择覆盖或跳过

#### Scenario: 批量下载时本地目标文件已存在

- **GIVEN** 批量下载远程多个项目到本地，其中某个文件在本地已存在
- **WHEN** 系统检测到该目标文件
- **THEN** 传输暂停于该文件，返回覆盖确认请求，用户可选择覆盖或跳过

### Requirement: 批量传输支持跳过单个项目

用户选择跳过单个冲突文件后，批量传输 SHALL 继续处理剩余项目，并将该文件标记为已跳过。整个批量传输 SHALL 在其余项目处理完毕后视为完成，不因单个跳过而失败。

#### Scenario: 用户跳过批量中的某个文件

- **GIVEN** 批量传输中某文件触发覆盖确认
- **WHEN** 用户选择跳过
- **THEN** 该文件不被写入，传输继续处理后续项目，最终批量任务成功完成

### Requirement: 批量传输支持取消

用户取消批量传输任务时，系统 SHALL 停止后续项目传输。已完成的项目保留，正在进行的项目按当前实现行为处理（可能部分写入），未开始的项目不再传输。

#### Scenario: 用户中途取消批量上传

- **GIVEN** 批量上传已完成 3 个项目，第 4 个项目正在传输
- **WHEN** 用户点击取消
- **THEN** 第 4 个项目传输停止，已完成的 3 个项目保留，剩余项目不再传输

### Requirement: 批量传输错误隔离

单个项目传输失败（如权限不足、网络中断） SHALL 不中断整个批量传输，除非用户设置「遇到错误立即停止」。默认行为 SHALL 记录该项目错误并继续传输其余项目，任务完成后展示错误摘要。

#### Scenario: 单个项目失败继续传输

- **GIVEN** 批量选择中有 5 个项目，其中 1 个因权限不足无法写入
- **WHEN** 系统传输该批量选择
- **THEN** 其余 4 个项目正常传输，失败项目记录错误，任务完成后显示 1 个错误

### Requirement: 批量传输避免符号链接循环

批量传输遍历本地或远程目录时，系统 SHALL 检测符号链接循环并在遇到循环时停止沿该路径继续遍历，避免无限递归。循环检测 SHALL 至少记录已访问的目录 inode（本地）或路径（远程）。

#### Scenario: 本地目录包含循环符号链接

- **GIVEN** 批量选中的某个本地目录 `a/link` 是指向 `a` 自身的符号链接
- **WHEN** 系统上传该批量选择
- **THEN** 系统识别循环，不上传 `a/link` 指向的内容，其他项目正常传输

### Requirement: 批量传输连接隔离

每个开始执行的批量传输任务 SHALL 建立并独占自己的 SSH Transport，可在该任务内部复用 SFTP Channel 扫描和传输其项目；任务完成、失败或取消后 SHALL 释放连接。不同批量任务及其来源 SFTP 标签 MUST NOT 共享 Socket。

#### Scenario: 两个批量任务连接同一主机

- **WHEN** 两个批量传输任务并发连接同一主机
- **THEN** 两个任务使用不同运行时连接标识，任一任务终止不影响另一个

#### Scenario: 批量任务取消

- **WHEN** 用户取消正在执行的批量任务
- **THEN** 该任务停止后释放自己的 SFTP Channel 与 SSH Transport
