## MODIFIED Requirements

### Requirement: 标签页会话关联

每个标签页 SHALL 基于一台已保存的主机建立会话。关闭某主机的最后一个标签页时，该主机的 SSH 连接 SHALL 被显式断开；但若该主机仍存在活跃传输任务（queued / running / paused），断开 SHALL 被推迟，直到最后一个活跃传输任务进入终态后再断开。

#### Scenario: 标签页基于已保存主机打开

- **WHEN** 用户从主机列表选择一台主机打开标签页
- **THEN** 该标签页使用该主机的地址、端口、用户名与认证方式建立会话

#### Scenario: 关闭最后一个标签页立即断开

- **GIVEN** 某主机只有一个标签页且无活跃传输任务
- **WHEN** 用户关闭该标签页
- **THEN** 该主机的 SSH 连接被立即断开

#### Scenario: 关闭 SFTP 标签页时存在活跃传输则推迟断开

- **GIVEN** 某主机的最后一个标签页为 SFTP 标签页，且该主机仍有 running 状态的传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 传输任务继续运行，SSH 连接此时 MUST NOT 被断开
- **AND** 当该主机的最后一个活跃传输任务进入终态后，SSH 连接被自动断开

### Requirement: SFTP 文件列表目录进入

SFTP 双栏文件列表 SHALL 支持双击目录进入子目录、双击文件创建传输任务；文件与目录 SHALL 均支持单击选中。双击文件 SHALL 创建且仅创建一个传输任务：本地面板文件触发上传、远程面板文件触发下载。双击目录 SHALL 进入该目录，MUST NOT 创建传输任务。

#### Scenario: 双击目录进入

- **GIVEN** 文件列表中显示目录 `ssh-test`
- **WHEN** 双击 `ssh-test`
- **THEN** 远程面板切换到 `ssh-test` 目录内容

#### Scenario: 双击本地文件触发上传

- **GIVEN** 本地面板中显示文件 `deploy.tar.gz`
- **WHEN** 双击 `deploy.tar.gz`
- **THEN** 系统为 `deploy.tar.gz` 创建一个上传任务到当前远程目录，且 MUST NOT 进入任何目录

#### Scenario: 双击远程文件触发下载

- **GIVEN** 远程面板中显示文件 `app.log`
- **WHEN** 双击 `app.log`
- **THEN** 系统为 `app.log` 创建一个下载任务到当前本地目录

#### Scenario: 单击选中目录

- **WHEN** 单击文件列表中的目录
- **THEN** 该目录高亮，但不进入

#### Scenario: 单击文件选中

- **GIVEN** 文件列表中显示文件 `upload-300m.bin`
- **WHEN** 单击 `upload-300m.bin`
- **THEN** 该行高亮，底部出现下载按钮

### Requirement: SFTP 文件行上下文菜单

SFTP 文件行 SHALL 支持右键（macOS）或长按（iPadOS）呼出原生上下文菜单，菜单项根据文件类型、所在面板与当前选中状态动态变化。单选模式下菜单作用于被右键的条目；多选模式下右键选中集合内任一条目时，菜单 SHALL 作用于整个选中集合，且右键未选中条目 SHALL 先将该条目置为唯一选中再展示菜单。菜单样式 SHALL 遵循系统原生风格，MUST NOT 使用自定义弹层。

#### Scenario: 右键远程文件

- **GIVEN** 远程面板中显示文件 `app.log`
- **WHEN** 右键 `app.log`
- **THEN** 弹出菜单，包含「下载」选项

#### Scenario: 右键本地目录

- **GIVEN** 本地面板中显示目录 `Documents`
- **WHEN** 右键 `Documents`
- **THEN** 弹出菜单，包含「进入」和「上传」选项

#### Scenario: 多选模式下右键集合内条目

- **GIVEN** 本地面板已多选 `a.txt` 与 `b.txt`
- **WHEN** 右键 `a.txt`
- **THEN** 弹出菜单，其中「上传」作用于 `a.txt` 与 `b.txt` 整个选中集合

#### Scenario: 多选模式下右键未选中条目

- **GIVEN** 本地面板已多选 `a.txt`，未选中 `c.txt`
- **WHEN** 右键 `c.txt`
- **THEN** 选中集合先变为仅 `c.txt`，再弹出作用于 `c.txt` 的菜单

## ADDED Requirements

### Requirement: 标签页右键上下文菜单

标签栏中的每个标签页 SHALL 支持右键（macOS）或长按（iPadOS）呼出上下文菜单，菜单至少包含「重连」「关闭其他标签页」「关闭全部标签页」三项。「重连」SHALL 仅对终端标签页生效，对 SFTP 标签页 SHALL 为禁用态或不展示。「关闭其他标签页」SHALL 关闭除当前右键标签页外的全部标签页。「关闭全部标签页」SHALL 关闭工作区中的全部标签页。批量关闭时，每个被关闭的终端标签页 SHALL 走与单标签关闭一致的连接释放与（终端）二次确认流程。

#### Scenario: 右键终端标签重连

- **GIVEN** 一个已连接的终端标签页
- **WHEN** 右键该标签并选择「重连」
- **THEN** 该终端标签断开当前 shell 会话并重新建立连接

#### Scenario: 关闭其他标签页

- **GIVEN** 工作区有标签页 A、B、C，用户右键 B
- **WHEN** 选择「关闭其他标签页」
- **THEN** A 与 C 被关闭，B 保留为活动标签

#### Scenario: 关闭全部标签页

- **GIVEN** 工作区有标签页 A、B、C
- **WHEN** 用户在任一标签页右键并选择「关闭全部标签页」
- **THEN** A、B、C 全部被关闭，工作区回到无活动标签的空态

#### Scenario: SFTP 标签页重连不可用

- **GIVEN** 一个 SFTP 标签页
- **WHEN** 右键该标签页
- **THEN** 「重连」项为禁用态或不展示

### Requirement: SSH 终端标签页关闭二次确认

用户关闭处于「已连接」状态的 SSH 终端标签页时，系统 SHALL 弹出二次确认对话框，询问是否关闭并断开会话。对话框样式 SHALL 遵循 macOS / iPadOS 原生规范（macOS 使用 `.confirmationDialog` 或系统 alert，iPadOS 使用同族原生弹窗）。用户确认后 SHALL 关闭标签页并断开会话；取消则保留标签页与会话。连接中或连接失败状态的终端标签页关闭时 SHALL 不弹出确认，直接关闭。

#### Scenario: 关闭已连接终端弹确认

- **GIVEN** 一个处于已连接状态的终端标签页
- **WHEN** 用户点击标签页关闭按钮
- **THEN** 弹出原生确认对话框；用户确认后才关闭并断开会话

#### Scenario: 取消关闭保留会话

- **GIVEN** 一个处于已连接状态的终端标签页，已弹出关闭确认
- **WHEN** 用户选择「取消」
- **THEN** 标签页保留，shell 会话不断开

#### Scenario: 关闭连接中标签页不弹确认

- **GIVEN** 一个处于连接中状态的终端标签页
- **WHEN** 用户点击标签页关闭按钮
- **THEN** 不弹出确认，直接关闭该标签页

### Requirement: SFTP 标签页关闭与传输延续

关闭 SFTP 标签页 SHALL NOT 取消或中断该主机正在进行或排队的传输任务。传输任务 SHALL 在源 SFTP 标签页关闭后继续按原有并发、暂停、重试语义运行至终态。当某主机已无打开的标签页且无活跃传输任务时，系统 SHALL 释放该主机的 SSH 连接。

#### Scenario: 关闭 SFTP 标签页后传输继续

- **GIVEN** 某 SFTP 标签页有 2 个 running 与 1 个 queued 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 3 个任务均不被取消，queued 任务随后按并发限制被调度执行

#### Scenario: 全部传输完成且无标签页后释放连接

- **GIVEN** 某主机的 SFTP 标签页已关闭，仍有 1 个 running 传输任务
- **WHEN** 该传输任务完成进入终态
- **THEN** 该主机的 SSH 连接被自动释放

#### Scenario: 仍有标签页时传输完成不断开

- **GIVEN** 某主机仍打开着一个终端标签页，其 SFTP 标签页已关闭且最后一个传输任务刚完成
- **WHEN** 传输任务进入终态
- **THEN** 该主机的 SSH 连接保持不变（因仍有终端标签页在使用）

### Requirement: SFTP 路径导航可输入跳转

SFTP 文件浏览面板顶部的路径导航 SHALL 支持直接输入路径跳转：用户点击导航区域 SHALL 进入可编辑输入态，输入完整路径并确认后，对应面板 SHALL 尝试导航到该路径；路径非法或不可访问时 SHALL 保持当前目录并提示错误，MUST NOT 静默跳转。取消编辑 SHALL 回到原导航展示态。本地面板与远程面板 SHALL 独立支持该能力。

#### Scenario: 输入远程路径跳转

- **GIVEN** 远程面板当前位于 `/home/user`
- **WHEN** 用户点击路径导航进入输入态，输入 `/var/log` 并确认
- **THEN** 远程面板导航到 `/var/log` 并列出其内容

#### Scenario: 输入非法路径保持原目录

- **GIVEN** 远程面板当前位于 `/home/user`
- **WHEN** 用户输入 `/no/such/dir` 并确认
- **THEN** 远程面板保持 `/home/user`，并展示路径不可访问的提示

#### Scenario: 取消编辑恢复导航

- **GIVEN** 用户已点击路径导航进入输入态
- **WHEN** 用户按下取消（Esc）或点击导航区域外
- **THEN** 回到原面包屑展示态，当前目录不变

### Requirement: 主窗口工具栏精简

主窗口 SHALL NOT 展示无意义的 `>>` 按钮。主窗口右上角 SHALL NOT 出现该多余控件；若其为系统自动注入的侧栏切换入口，SHALL 通过隐藏或移除该自动注入项实现。

#### Scenario: 主窗口右上角无多余按钮

- **WHEN** 用户打开主窗口
- **THEN** 主窗口右上角不出现 `>>` 形状的多余按钮
