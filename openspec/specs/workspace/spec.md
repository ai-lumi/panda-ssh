# workspace Specification

## Purpose
多标签页工作区是 App 的主界面形态：用户可在同一窗口中同时打开多个服务器会话，每个会话以「终端」或「SFTP 文件浏览器」标签页呈现，并可自由切换与关闭。
## Requirements
### Requirement: 多标签页工作区

系统 SHALL 提供标签页工作区，允许同时打开多个标签页并展示一个当前活动标签页。

#### Scenario: 打开多个标签页

- **GIVEN** 用户已保存至少两台服务器主机
- **WHEN** 用户依次从两台主机打开新的标签页
- **THEN** 工作区中同时显示两个标签页，且同一时刻仅有一个活动标签页

#### Scenario: 关闭标签页

- **WHEN** 用户关闭一个标签页
- **THEN** 该标签页及其服务器会话被释放，其余标签页不受影响

#### Scenario: 同一主机打开多个标签页

- **GIVEN** 用户已为某主机打开一个标签页
- **WHEN** 用户再次从该主机选择「终端」或「SFTP」
- **THEN** 系统总是新建一个标签页，MUST NOT 复用或激活已有标签页
- **AND** 新标签页持有独立于已有标签页的服务器会话

#### Scenario: 从标签栏新建标签页

- **GIVEN** 侧栏已选中一台主机
- **WHEN** 用户点击标签栏的「+」并选择「终端」或「SFTP」
- **THEN** 为该主机新建对应类型的标签页并成为活动标签

#### Scenario: 未选中主机时新建入口禁用

- **GIVEN** 侧栏未选中任何主机
- **WHEN** 展示标签栏
- **THEN** 「+」新建入口为禁用态

### Requirement: 标签页标题消歧

同一主机存在多个标签页时，系统 SHALL 在标签页标题中添加区分标识，MUST NOT 出现两个无法区分的同名标签。

#### Scenario: 同主机多标签编号

- **GIVEN** 工作区中已存在某主机的一个或多个标签页
- **WHEN** 用户再次为该主机打开标签页
- **THEN** 各标签页标题带序号等区分标识（如「web-prod (2)」）

### Requirement: 标签页类型

标签页 SHALL 为「终端」或「SFTP 文件浏览器」两种类型之一，且同一工作区可同时包含两种类型。

#### Scenario: 新建终端标签页

- **GIVEN** 用户选择一台服务器并选择「终端」
- **WHEN** 打开该标签页
- **THEN** 标签页内显示该服务器的交互式终端会话

#### Scenario: 新建 SFTP 标签页

- **GIVEN** 用户选择一台服务器并选择「SFTP」
- **WHEN** 打开该标签页
- **THEN** 标签页内显示该服务器的 SFTP 文件浏览器

### Requirement: SFTP 双栏文件浏览器

SFTP 标签页 SHALL 以左栏本地文件系统、右栏远程文件系统的双栏布局展示，并允许在两侧切换目录。

#### Scenario: 查看本地与远程目录

- **GIVEN** 用户已打开某服务器的 SFTP 标签页
- **WHEN** 用户在左栏切换到本地某个目录、在右栏切换到远程某个目录
- **THEN** 左栏显示本地目录内容，右栏显示远程目录内容

### Requirement: 标签页会话关联

每个标签页 SHALL 基于一台已保存的主机建立会话，标签页关闭时该会话 MUST 被断开。

#### Scenario: 标签页基于已保存主机打开

- **WHEN** 用户从主机列表选择一台主机打开标签页
- **THEN** 该标签页使用该主机的地址、端口、用户名与认证方式建立会话

### Requirement: 连接失败提示

标签页在建立会话失败时 SHALL 在标签页内容区展示错误信息，且 MUST NOT 导致 App 崩溃或影响其它标签页。

#### Scenario: 连接失败展示错误

- **GIVEN** 服务器不可达或认证失败
- **WHEN** 用户从该主机打开标签页
- **THEN** 标签页内显示失败原因，并提供「重试」或「关闭」操作

### Requirement: 侧栏主机行单击选中

侧栏主机行 SHALL 支持单击选中；打开终端等操作通过右键/长按上下文菜单提供。

#### Scenario: 单击主机

- **WHEN** 单击侧栏中的主机行
- **THEN** 该行高亮，右侧显示主机详情

#### Scenario: 双击主机

- **GIVEN** 侧栏中的主机行
- **WHEN** 双击该行
- **THEN** 不触发任何操作；打开终端已移至右键/长按菜单

#### Scenario: 右键主机打开终端

- **GIVEN** 侧栏中显示主机 `web-prod`
- **WHEN** 右键 `web-prod` 并选择「打开终端」
- **THEN** 为该主机新建终端标签页

### Requirement: 面包屑不重复 rootTitle

SFTP 双栏顶部的面包屑 SHALL 不重复显示已作为栏头标签出现的 rootTitle。

#### Scenario: 在远程根目录

- **GIVEN** 远程 rootTitle 为「远程 — ssh-test」
- **WHEN** 当前路径等于根目录
- **THEN** 面包屑区域为空，仅左侧栏头显示「远程 — ssh-test」

### Requirement: SFTP 文件列表目录进入

SFTP 双栏文件列表 SHALL 支持双击目录进入子目录；文件与目录 SHALL 均支持单击选中。

#### Scenario: 双击目录进入

- **GIVEN** 文件列表中显示目录 `ssh-test`
- **WHEN** 双击 `ssh-test`
- **THEN** 远程面板切换到 `ssh-test` 目录内容

#### Scenario: 单击选中目录

- **WHEN** 单击文件列表中的目录
- **THEN** 该目录高亮，但不进入

#### Scenario: 单击文件选中

- **GIVEN** 文件列表中显示文件 `upload-300m.bin`
- **WHEN** 单击 `upload-300m.bin`
- **THEN** 该行高亮，底部出现下载按钮

### Requirement: 返回顶级目录

SFTP 双栏顶部标题 SHALL 作为返回顶级目录的入口；点击后当前面板 SHALL 回到根目录。

#### Scenario: 点击标题返回顶级

- **GIVEN** 用户已深入 `ssh-test/sub/dir`
- **WHEN** 点击顶部「远程 — host.name」标题
- **THEN** 远程面板回到 `/share/homes/lwq/ssh-test`（该面板 root）

### Requirement: SFTP 文件行上下文菜单

SFTP 文件行 SHALL 支持右键（macOS）或长按（iPadOS）呼出上下文菜单，菜单项根据文件类型与所在面板动态变化。

#### Scenario: 右键远程文件

- **GIVEN** 远程面板中显示文件 `app.log`
- **WHEN** 右键 `app.log`
- **THEN** 弹出菜单，包含「下载」选项

#### Scenario: 右键本地目录

- **GIVEN** 本地面板中显示目录 `Documents`
- **WHEN** 右键 `Documents`
- **THEN** 弹出菜单，包含「进入」和「上传」选项

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

### Requirement: SFTP 文件列表删除

SFTP 文件列表的每一行 SHALL 在右键（macOS）或长按（iPadOS）菜单中提供「删除」选项；删除前 SHALL 弹出二次确认框；确认后本地条目 SHALL 通过文件系统删除，远程条目 SHALL 通过 SFTP 删除。

#### Scenario: 删除本地文件

- **GIVEN** 本地文件列表中有一个文件 `report.pdf`
- **WHEN** 用户右键/长按该文件并选择「删除」，然后在确认框中确认
- **THEN** `report.pdf` 从本地文件系统删除，本地面板自动刷新

#### Scenario: 删除远程空目录

- **GIVEN** 远程文件列表中有一个空目录 `old-logs`
- **WHEN** 用户右键/长按该目录并选择「删除」，然后在确认框中确认
- **THEN** `old-logs` 从远端删除，远程面板自动刷新

#### Scenario: 取消删除

- **GIVEN** 用户右键/长按某个文件并选择「删除」
- **WHEN** 用户在确认框中选择「取消」
- **THEN** 该文件/目录未被删除

### Requirement: 传输面板按任务组展示

传输面板 SHALL 将具有相同 `groupID` 的任务聚合在同一任务组下展示，无 `groupID` 的任务作为独立任务展示。每个任务组 SHALL 显示组名、组内进度汇总与批量操作按钮，组内每个文件任务 SHALL 显示独立进度与操作。

#### Scenario: 目录传输任务组展示

- **GIVEN** 目录 `backup` 的上传生成了 3 个文件任务
- **WHEN** 打开传输面板
- **THEN** 面板中显示一个名为 `backup` 的组，组内列出 3 个文件任务，每个任务有自己的进度条和取消/重试按钮，组头有「停止全部」和「重试失败」按钮

#### Scenario: 独立任务与任务组共存

- **GIVEN** 队列中有一个目录任务组 `backup` 和一个独立文件任务 `report.pdf`
- **WHEN** 打开传输面板
- **THEN** `backup` 组与 `report.pdf` 独立任务均可见，互不影响

