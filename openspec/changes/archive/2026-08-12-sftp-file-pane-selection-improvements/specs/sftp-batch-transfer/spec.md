## MODIFIED Requirements

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

## ADDED Requirements

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
