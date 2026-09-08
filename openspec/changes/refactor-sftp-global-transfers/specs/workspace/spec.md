## ADDED Requirements

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
