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

### Requirement: 页签栏溢出显示模式

macOS 页签栏 SHALL 支持两种溢出显示模式：左右滚动（默认）与多行显示。用户 SHALL 在「设置 → 外观」中选择模式，选择结果 SHALL 持久化并在下次启动时生效。页签栏高度 SHALL 根据当前模式的内容自适应，MUST NOT 使用固定高度。

#### Scenario: 滚动模式支持鼠标滚轮

- **GIVEN** 用户在设置中选择「左右滚动」模式
- **WHEN** 页签数量超出页签栏可见宽度
- **THEN** 用户可通过鼠标滚轮在页签栏上横向滚动查看全部页签

#### Scenario: 滚动模式翻页按钮

- **GIVEN** 用户在设置中选择「左右滚动」模式，且页签数量超出可见宽度
- **WHEN** 页签栏左右两侧显示「上一页」「下一页」翻页按钮
- **THEN** 点击按钮按可见宽度翻页，到达边界时按钮禁用，MUST NOT 越界滚动
- **AND** 页签数量未超出可见宽度时，翻页按钮隐藏

#### Scenario: 多行显示模式自动换行

- **GIVEN** 用户在设置中选择「多行显示」模式
- **WHEN** 页签数量超出页签栏可见宽度
- **THEN** 页签按流水布局自动换行展示，页签栏高度随行数增加而增加

#### Scenario: 模式切换立即生效

- **GIVEN** 工作区已打开若干页签
- **WHEN** 用户在「设置 → 外观」中切换页签栏溢出模式
- **THEN** 页签栏立即按新模式渲染，无需重启 App

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

每个终端或 SFTP 标签 SHALL 基于一台已保存的主机建立并独占自己的 SSH Transport。关闭标签页 SHALL 精确关闭该标签拥有的连接，MUST NOT 按主机断开其他标签或后台传输。后台传输 SHALL 独立拥有连接，不参与标签页连接的延迟释放协调。

#### Scenario: 标签页基于已保存主机打开

- **WHEN** 用户从主机列表选择一台主机打开标签页
- **THEN** 该标签页使用该主机的地址、端口、用户名与认证方式建立自己的会话

#### Scenario: 关闭终端标签精确断开

- **GIVEN** 某主机有两个终端标签
- **WHEN** 用户关闭其中一个标签
- **THEN** 系统立即关闭该标签拥有的连接，另一个标签的连接保持不变

#### Scenario: 关闭 SFTP 标签不影响传输

- **GIVEN** 某 SFTP 标签创建了仍在运行的后台传输
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 系统关闭该标签自己的 SFTP 连接，后台传输使用自己的连接继续运行

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

### Requirement: 返回顶级目录

SFTP 双栏顶部标题 SHALL 作为返回顶级目录的入口；点击后当前面板 SHALL 回到根目录。

#### Scenario: 点击标题返回顶级

- **GIVEN** 用户已深入 `ssh-test/sub/dir`
- **WHEN** 点击顶部「远程 — host.name」标题
- **THEN** 远程面板回到 `/share/homes/lwq/ssh-test`（该面板 root）

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

关闭 SFTP 标签页 SHALL 精确关闭该标签拥有的 SFTP 会话，且 MUST NOT 取消或中断该主机正在进行或排队的传输任务。传输任务 SHALL 使用自身连接继续按原有并发、暂停、重试语义运行至终态，并在终态释放自己的连接。

#### Scenario: 关闭 SFTP 标签页后传输继续

- **GIVEN** 某 SFTP 标签页有 2 个 running 与 1 个 queued 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 标签页连接被释放，3 个任务均不被取消，queued 任务随后按并发限制被调度执行

#### Scenario: 全部传输完成后释放任务连接

- **GIVEN** SFTP 标签页已关闭，仍有 1 个 running 传输任务
- **WHEN** 该传输任务完成进入终态
- **THEN** 该任务拥有的 SSH 连接被自动释放

#### Scenario: 传输终态不影响其他标签

- **GIVEN** 某主机仍打开着一个终端标签且最后一个传输任务刚完成
- **WHEN** 传输任务进入终态
- **THEN** 终端标签拥有的连接保持不变

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

macOS 主窗口 SHALL 保留系统工具栏：macOS 26 起，窗口持有可见系统工具栏是侧栏浮动面板融入标题栏的前提（融合由工具栏驱动，移除工具栏或剔除工具栏项均会失去融合）。侧栏顶部工具条（添加主机/新建分组/隐藏侧栏按钮）SHALL 与窗口红绿灯同一水平线。detail 区顶部 SHALL 容忍系统工具栏绘制带存在，MUST NOT 用自绘内容遮盖、填充或替代该带。主窗口 SHALL NOT 展示无意义的 `>>` 溢出按钮；若其为系统自动注入的溢出入口，SHALL 通过保证侧栏最小宽度等方式消除。iPadOS 端布局与入口 SHALL 保持既有行为不变。

#### Scenario: 侧栏融入标题栏

- **WHEN** 用户打开主窗口
- **THEN** 侧栏面板顶边延伸到窗口顶部，侧栏顶部工具条按钮与红绿灯同一水平线

#### Scenario: detail 区顶部保留系统工具栏带

- **WHEN** 用户打开主窗口
- **THEN** detail 区顶部显示系统工具栏绘制带，页签栏位于该带下方
- **AND** 该带区域不出现自绘内容或遮盖层

#### Scenario: 侧栏隐藏时由系统按钮唤回

- **WHEN** 用户隐藏侧栏
- **THEN** 系统侧栏切换按钮出现在标题栏红绿灯右侧，点击可唤回侧栏
- **AND** detail 区不出现自绘的「显示侧栏」按钮，同一时刻不存在两个显隐按钮

#### Scenario: 主窗口右上角无多余按钮

- **WHEN** 用户打开主窗口
- **THEN** 主窗口右上角不出现 `>>` 形状的多余按钮

#### Scenario: iPadOS 布局不变

- **WHEN** 在 iPadOS 上打开主窗口
- **THEN** 侧栏布局、搜索入口与添加按钮入口（系统导航栏）保持既有行为，不受 macOS 工具栏策略影响

### Requirement: 连接监控页面入口

macOS 与 iPadOS 的工作区 SHALL 提供进入连接监控页面的入口。macOS 入口 SHALL 在独立窗口展示连接监控，并在窗口已存在时激活该窗口；打开或激活监控窗口 MUST NOT 替换主窗口内容，也 MUST NOT 修改主窗口的主机、分组、标签页或工作区呈现选择。iPadOS 入口 SHALL 继续在主工作区内展示连接监控页面。该页面 SHALL 展示 FFI 返回的当前连接与通道快照，并支持用户手动刷新及对单条连接发起健康检查。页面刷新 MUST NOT 建立新连接或改变工作区标签页。

#### Scenario: 手动刷新监控页面
- **GIVEN** 用户已打开连接监控页面
- **WHEN** 用户选择刷新
- **THEN** 页面显示最新可用快照，且现有终端、SFTP 标签页和连接状态不因刷新而改变

#### Scenario: 双平台入口可达
- **WHEN** 用户在 macOS 或 iPadOS 的工作区选择连接监控入口
- **THEN** 系统按照各平台的呈现策略展示同一语义的连接监控页面和空状态处理

#### Scenario: macOS 独立窗口入口
- **GIVEN** macOS 主窗口正在展示主机详情、终端或 SFTP 工作区
- **WHEN** 用户选择连接监控入口
- **THEN** 系统打开或激活独立的连接监控窗口，且主窗口内容与选择保持不变

#### Scenario: iPadOS 工作区入口
- **WHEN** 用户在 iPadOS 工作区选择连接监控入口
- **THEN** 系统在主工作区展示连接监控页面和空状态处理
