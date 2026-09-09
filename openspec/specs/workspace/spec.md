# workspace Specification

## Purpose
多标签页工作区是 App 的主界面形态：用户可在同一窗口中同时打开多个服务器会话，每个会话以「终端」或「SFTP 文件浏览器」标签页呈现，并可自由切换与关闭。
## Requirements
### Requirement: 多标签页工作区

系统 SHALL 提供标签页工作区，允许同时打开多个标签页并展示一个当前活动标签页。页签关闭控件的整个可见圆角矩形 SHALL 触发关闭动作，MUST NOT 仅由 X 图标区域触发。页签胶囊的整个可见区域 SHALL 触发选择操作；关闭控件 SHALL 作为独立子操作处理，MUST NOT 同时触发页签选择。每个标签页的状态点 SHALL 表示该标签页自身的当前会话状态：连接中、已连接或已断开/失败；MUST NOT 用已记录主机密钥等安全元数据代替会话状态。侧栏主机状态点 SHALL 聚合该主机所有已打开标签页的当前会话状态：任一会话已连接时表示可达；否则表示尚无可用会话。系统 SHALL NOT 为刷新状态点而对没有已打开会话的主机发起后台网络探测。

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

#### Scenario: 点击关闭控件边缘

- **GIVEN** 页签的关闭控件可见
- **WHEN** 用户点击该控件可见圆角矩形内、但不在 X 图标上的位置
- **THEN** 系统按既有关闭规则请求关闭该页签

#### Scenario: 点击页签上下留白切换

- **GIVEN** 页签的视觉高度大于标题行高
- **WHEN** 用户点击页签胶囊内标题上下的留白区域
- **THEN** 系统切换到该页签

#### Scenario: 点击关闭控件不切换

- **GIVEN** 页签关闭控件可见
- **WHEN** 用户点击关闭控件
- **THEN** 系统仅按既有规则请求关闭该页签
- **AND** 系统不执行页签选择操作

#### Scenario: 终端读循环发现会话断开

- **GIVEN** 一个终端标签页处于已连接状态
- **WHEN** 终端读循环报告 SSH 通道错误
- **THEN** 该标签页状态点 SHALL 不再显示已连接
- **AND** 当该主机没有其他已连接标签页时，侧栏主机状态点 SHALL 表示无可用会话

#### Scenario: 同一主机有并行会话

- **GIVEN** 同一主机有两个已打开标签页，其中一个连接失败
- **WHEN** 另一个标签页保持已连接
- **THEN** 失败标签页 SHALL 显示失败状态
- **AND** 侧栏主机状态点 SHALL 仍表示可达

#### Scenario: 未打开会话的主机

- **GIVEN** 一台主机没有已打开标签页
- **WHEN** 渲染侧栏主机行
- **THEN** 状态点 SHALL 表示未建立会话
- **AND** 系统 MUST NOT 因此发起网络探测

### Requirement: 页签栏溢出显示模式

macOS 与 iPadOS 页签栏 SHALL 使用共享单行水平滚动容器。溢出时 SHALL 提供左右浏览控件及滚动输入；浏览 MUST NOT 切换活动页签。应用 MUST NOT 提供旧版多行显示设置。

#### Scenario: 大量页签

- **WHEN** 页签总宽度超过视口
- **THEN** 可在容器边界内浏览所有页签，主内容区不因多行换行而下移

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

全局传输页面 SHALL 将具有相同 `groupID` 的任务聚合在同一任务组下展示，无 `groupID` 的任务作为独立任务展示。每个任务组 SHALL 显示组名、组内进度汇总与批量操作按钮，组内每个文件任务 SHALL 显示独立进度与操作。

#### Scenario: 目录传输任务组展示

- **GIVEN** 目录 `backup` 的上传生成了 3 个文件任务
- **WHEN** 打开全局传输页面
- **THEN** 面板中显示一个名为 `backup` 的组，组内列出 3 个文件任务，每个任务有自己的进度条和取消/重试按钮，组头有「停止全部」和「重试失败」按钮

#### Scenario: 独立任务与任务组共存

- **GIVEN** 队列中有一个目录任务组 `backup` 和一个独立文件任务 `report.pdf`
- **WHEN** 打开全局传输页面
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

SFTP 本地与远程面板 SHALL 独立提供始终可见的路径编辑入口，包括初始目录、文件系统根和 home 外目录。点击入口 SHALL 进入输入态，输入绝对路径并确认后 SHALL 尝试读取该目录。路径和列表 MUST 在成功读取后一起生效；失败 SHALL 保持当前路径、列表和选择并提示错误。取消编辑 SHALL 回到原导航展示态。相对路径、空输入和包含 NUL 的路径 MUST 被拒绝；末尾分隔符 SHALL 统一处理，中文与空格 MUST 保留。

#### Scenario: 输入远程路径跳转

- **GIVEN** 远程面板在 `/home/user`
- **WHEN** 用户点击路径编辑入口，输入 `/var/log/` 并确认
- **THEN** 读取成功后地址显示 `/var/log`，列表显示该目录内容，清空旧选择

#### Scenario: 输入非法路径保持原目录

- **GIVEN** 远程面板在 `/home/user`
- **WHEN** 用户输入不可访问或非法路径并确认
- **THEN** 远程面板保持原路径、列表和选择，并展示错误

#### Scenario: 取消编辑恢复导航

- **GIVEN** 用户已进入路径输入态
- **WHEN** 用户按下取消（Esc）或点击导航区域外
- **THEN** 回到原面包屑展示态，当前目录和列表不变

#### Scenario: 导航加载与乱序响应

- **WHEN** 用户从 A 请求 B，再请求 C，B 的结果晚于 C 返回
- **THEN** 加载成功前保留上一份成功目录和列表；C 成功后 B 的成功或失败 MUST NOT 覆盖 C 的状态

#### Scenario: 根目录和 home 外目录

- **WHEN** 用户跳转到 `/` 或 home 外的目录
- **THEN** 路径编辑入口仍可见，面包屑能呈现当前位置；`/` 下返回上级为无操作

#### Scenario: 跳转期间自动刷新

- **WHEN** 用户正在跳转到新目录，同时传输完成触发当前目录自动刷新
- **THEN** 自动刷新 MUST NOT 取消该跳转或把面板恢复到旧目录

#### Scenario: 进入子目录失败

- **WHEN** 双击目录或返回上级时读取失败
- **THEN** 系统保持上一份成功目录和列表并暴露错误状态

### Requirement: 主窗口工具栏精简

macOS SHALL 保留原生窗口控制、缩放、全屏与空白拖拽。应用 SHALL 使用透明标题栏、全尺寸内容及实测红绿灯安全区承载唯一统一顶部 chrome，MUST NOT 使用系统 toolbar 或 principal item 承载页签。iPadOS SHALL 在系统导航栏使用同一页签容器，并保留系统侧栏恢复入口及安全区。应用 MUST NOT 装配旧内容区页签栏。

#### Scenario: 打开双端工作区

- **WHEN** 用户在 macOS 或 iPadOS 打开工作区
- **THEN** 顶部仅有一个页签容器，平台原生控制可用

### Requirement: macOS 主窗口工具带布局

macOS SHALL 在唯一顶行中显示侧栏操作区与独立页签容器，下方由 NSSplitViewController 承载共享侧栏及内容视图。顶行 SHALL 使用实测侧栏宽度和原生窗口安全区；iPadOS SHALL 保留 NavigationSplitView 与系统导航栏。

#### Scenario: 打开工作区

- **WHEN** 用户打开工作区
- **THEN** 系统按上述约束呈现统一 UI

### Requirement: 隐藏/显示左侧边栏入口

macOS 统一顶行 SHALL 在侧栏显示时提供隐藏侧栏按钮，隐藏后提供恢复侧栏按钮。按钮 MUST NOT 在旧内容区工具带或侧栏内重复出现。

#### Scenario: 切换侧栏

- **WHEN** 用户点击顶行侧栏按钮
- **THEN** 侧栏可隐藏并恢复，页签与会话保持不变

### Requirement: 页签按钮平铺与溢出处理

页签 SHALL 在统一顶部容器中水平排列，溢出时通过滚动及左右浏览按钮显露。应用 MUST NOT 根据历史多行显示偏好启用旧布局。

#### Scenario: 历史偏好

- **WHEN** 历史溢出模式为多行、空值或非法值
- **THEN** 仍使用统一单行容器，不读取或改写旧偏好

### Requirement: 主内容区空态

当 macOS 工作区没有任何标签页时，主内容区 SHALL 显示空态：中央终端图标、标题「尚未连接」、副标题「选择一个主机或打开一个已有的连接」、「快速连接」与「打开连接」两个按钮。

#### Scenario: 关闭所有标签页

- **GIVEN** 用户关闭了所有标签页
- **THEN** 主内容区显示「尚未连接」空态，含「快速连接」「打开连接」按钮

#### Scenario: 点击快速连接

- **GIVEN** 主内容区显示空态
- **WHEN** 用户点击「快速连接」
- **THEN** 系统弹出快速连接对话框

#### Scenario: 点击打开连接

- **GIVEN** 主内容区显示空态
- **WHEN** 用户点击「打开连接」
- **THEN** 系统打开连接选择/历史连接面板

### Requirement: macOS 侧栏顶部主机管理按钮

macOS 主窗口 SHALL 在左侧栏顶部的标题栏区域（与窗口红绿灯同一水平线、位于侧栏列范围内）放置「添加主机」与「新建分组」按钮。这两个按钮 SHALL NOT 出现在窗口顶部标题栏的导航区（detail 内容区一侧）。按钮 SHALL 随侧栏显隐：侧栏隐藏时按钮不可见。该布局 SHALL 仅适用于 macOS 端，iPadOS 端不出现这两个按钮、布局与入口保持不变。

#### Scenario: 侧栏顶部展示主机管理按钮

- **WHEN** 用户在 macOS 打开主窗口且左侧栏可见
- **THEN** 左侧栏顶部的标题栏区域可见「添加主机」「新建分组」按钮，且窗口顶部标题栏的导航区不出现这两个按钮

#### Scenario: 点击添加主机

- **GIVEN** macOS 主窗口左侧栏可见
- **WHEN** 用户点击侧栏顶部的「添加主机」按钮
- **THEN** 弹出添加主机编辑页

#### Scenario: 点击新建分组

- **GIVEN** macOS 主窗口左侧栏可见
- **WHEN** 用户点击侧栏顶部的「新建分组」按钮
- **THEN** 弹出新建分组输入框

#### Scenario: 侧栏隐藏时按钮不可见

- **WHEN** 用户在 macOS 隐藏左侧栏
- **THEN** 「添加主机」「新建分组」按钮随侧栏一起隐藏，不再出现在窗口任何位置

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

### Requirement: 主窗口左下角功能入口
主窗口左下角 SHALL 在连接监控附近提供「传输任务」入口及活动任务数，MUST NOT 展示预留的「代码片段」按钮。代码片段功能暂不纳入本次实现范围。

#### Scenario: 查看左下角入口
- **WHEN** 用户查看主窗口左下角功能区
- **THEN** 可进入全局传输任务和连接监控，且不显示代码片段按钮

### Requirement: SFTP 紧凑顶部布局
SFTP 页签栏与文件地址栏之间 MUST NOT 展示额外的 SFTP 标题栏或传输工具栏。地址栏 SHALL 保留本地／远程标识与原有目录导航操作；窄屏 SHALL 保留本地／远程切换能力。本地地址栏 MUST NOT 展示上传按钮；选中文件后的底部上传入口 SHALL 保留。

#### Scenario: 打开 SFTP
- **WHEN** 用户打开 SFTP 页签
- **THEN** 文件浏览区域直接呈现地址导航，不出现重复的 SFTP 标题工具栏

### Requirement: SFTP 指针反馈
macOS SFTP 地址栏图标、刷新和选择等按钮 SHALL 使用系统箭头光标；可编辑路径文字区域 SHALL 使用文本光标。离开文本区域后 MUST NOT 在按钮上残留 I 形光标。

#### Scenario: 路径输入后移到按钮
- **WHEN** 用户编辑路径后把鼠标移到图标、刷新或选择按钮
- **THEN** 指针恢复箭头，移回可编辑文字区域时显示文本光标

#### Scenario: 从终端切换到 SFTP
- **WHEN** 用户从终端切换到 SFTP 并将鼠标移到地址栏按钮
- **THEN** 按钮上不残留终端的文本光标

### Requirement: 全局传输页面
工作区 SHALL 提供全局传输任务入口。macOS SHALL 打开或激活唯一的独立传输窗口；iPadOS SHALL 在工作区展示独立传输页面。页面 SHALL 展示全部主机的共享任务，MUST NOT 使用 SFTP 侧滑栏、inspector 或 sheet。创建任务 SHALL 提示入队，MUST NOT 自动打开或切换到传输页面。关闭页面 MUST NOT 中断任务。

#### Scenario: 无 SFTP 页签时查看任务
- **WHEN** 用户关闭全部 SFTP 页签后打开传输任务
- **THEN** 仍能查看及管理已有任务

#### Scenario: 重复打开 macOS 页面
- **WHEN** 用户多次点击传输入口
- **THEN** 激活同一个传输窗口，主窗口选择不变

#### Scenario: iPadOS 独立页面
- **WHEN** 用户在 iPadOS 点击传输入口
- **THEN** 工作区显示传输页面，窄屏下所有任务字段仍可访问

### Requirement: macOS 顶部栏跨焦点与主机选择保持可见

macOS 主窗口 SHALL 在失焦、重新聚焦与选择主机后持续显示顶部主机管理按钮和页签栏，MUST NOT 因窗口样式重复配置而隐藏、遮挡或移出顶部可见区域。主机详情切换 SHALL 保留现有页签及后台会话。

#### Scenario: 窗口焦点往返
- **WHEN** 已显示顶部栏的主窗口失焦后重新聚焦
- **THEN** 顶部按钮、页签及原生窗口按钮持续可见，恢复焦点后仍可交互

#### Scenario: 选择主机
- **WHEN** 用户点击侧栏主机显示详情
- **THEN** 顶部按钮和已有页签保持可见，页签顺序及会话不变

#### Scenario: 无页签与窗口尺寸变化
- **WHEN** 没有打开页签，或窗口在受支持尺寸内缩放
- **THEN** 顶部主机管理入口及无页签提示保持可见，不出现整行消失

### Requirement: iPad 侧栏恢复入口唯一
iPad 工作区 SHALL 保留系统导航提供的侧栏恢复入口。统一页签栏 MUST NOT 重复绘制自定义恢复按钮，也 MUST NOT 为该按钮预留宽度。

#### Scenario: 隐藏和恢复侧栏
- **WHEN** 用户隐藏侧栏或反复切换侧栏显隐
- **THEN** 仅保留系统提供的恢复入口，页签栏不显示重复按钮

#### Scenario: 紧凑宽度
- **WHEN** iPad 旋转或进入窄分屏
- **THEN** 页签栏不为自定义恢复按钮占位，系统导航入口保持可用

### Requirement: iPad 导航与页签共用顶行
iPad 统一工作区 SHALL 在系统导航栏中展示页签，内容区 MUST NOT 再绘制独立页签行。系统侧栏入口和状态栏安全区 SHALL 保留。此装配 MUST NOT 改变 macOS 顶部栏布局。

#### Scenario: 侧栏显隐与旋转
- **WHEN** iPad 侧栏展开、隐藏或窗口宽度变化
- **THEN** 页签与系统导航共用一行，页签视口随可用宽度调整

#### Scenario: 多页签与空页签
- **WHEN** 页签为空或超出视口宽度
- **THEN** 显示既有空态或提供既有滚动交互，内容区不额外占用一行
