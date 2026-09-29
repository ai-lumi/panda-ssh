## MODIFIED Requirements

### Purpose

代码片段能力 SHALL 以 Markdown 文件管理常用命令与脚本片段，支持多级标签分类、全文搜索、参数化模板与终端选文入口，便于用户复用与手工维护。

### Requirement: 待深化能力约束

本节仅适用于「待深化」能力（多级标签、终端选文、搜索、模板），已实现的基础能力（CRUD、Markdown 存储、标签、界面）不受此约束。待深化能力 SHALL 按低优先级推进：规格与设计先行，实现阶段不占用当前排期，MUST NOT 阻塞其它能力的开发与交付。

#### Scenario: 待深化能力不影响主线开发

- **WHEN** 其它核心能力进入实现阶段
- **THEN** 待深化能力（多级标签、搜索、模板等）保持低优先级推进，已实现的基础能力不受此约束，不影响其它能力交付

#### Scenario: 基础能力不受深化约束

- **WHEN** 用户使用片段 CRUD、Markdown 存储或平级标签
- **THEN** 功能正常可用，不受深化能力排期影响

## ADDED Requirements

### Requirement: 多级标签

系统 SHALL 支持多级路径标签，使用 `/` 作为层级分隔符。每个片段可挂多个标签，标签本身具有层级结构。标签索引 SHALL 以 `tags.toml` 文件存储于片段存储目录，保存标签的独立元数据（颜色、描述）。标签树可从所有片段的 frontmatter 重建。

#### Scenario: 片段挂多级标签

- **GIVEN** 用户创建一个片段
- **WHEN** 用户设置标签为 `["网络/内核参数", "故障处理/生产事故"]`
- **THEN** 系统在 frontmatter 中保存路径字符串，标签树中"网络"下显示子标签"内核参数"

#### Scenario: 子树查询

- **GIVEN** 用户选择标签"网络"进行过滤
- **WHEN** 系统执行过滤
- **THEN** 匹配所有标签等于"网络"或以"网络/"开头的片段（如"网络/内核参数"、"网络/TCP 调优"）

#### Scenario: 过滤模式切换

- **GIVEN** 用户选择了多个标签进行过滤
- **WHEN** 用户切换过滤模式为 AND
- **THEN** 只显示同时匹配所有选中标签的片段；默认模式为 OR（匹配任一即显示）

#### Scenario: 空选择显示全部

- **GIVEN** 用户未选择任何标签
- **WHEN** 系统执行过滤
- **THEN** 显示所有片段

### Requirement: 标签管理

系统 SHALL 支持标签的创建、重命名、删除与树形浏览。重命名标签 SHALL 级联更新所有关联片段的 frontmatter。删除标签 SHALL 从所有片段中移除该标签，但不删除片段本身。

#### Scenario: 重命名标签级联更新

- **GIVEN** 标签"网络/内核参数"被 3 个片段使用
- **WHEN** 用户将"网络/内核参数"重命名为"网络/系统调优/内核参数"
- **THEN** 3 个片段的 frontmatter 中该标签更新为新路径；子标签（如"网络/内核参数/TCP"）也级联更新为"网络/系统调优/内核参数/TCP"

#### Scenario: 删除标签不删除片段

- **GIVEN** 标签"旧标签"被 2 个片段使用
- **WHEN** 用户删除"旧标签"
- **THEN** 2 个片段的 frontmatter 中移除"旧标签"，片段本身保留；子标签不受影响

#### Scenario: 标签索引重建

- **GIVEN** `tags.toml` 文件丢失或损坏
- **WHEN** 系统加载标签索引
- **THEN** 从所有片段的 frontmatter 重建派生树；已保存的元数据（颜色、描述）丢失后回退到默认值

### Requirement: 片段搜索

系统 SHALL 支持按关键词搜索片段，搜索范围包括标题、标签和内容。多个空格分隔的关键词为 AND 关系。搜索 SHALL 大小写不敏感。

#### Scenario: 关键词搜索

- **GIVEN** 存储目录中有若干片段
- **WHEN** 用户搜索 "deploy git"
- **THEN** 返回标题、标签或内容中同时包含 "deploy" 和 "git" 的片段

#### Scenario: 空搜索返回全部

- **GIVEN** 存储目录中有若干片段
- **WHEN** 用户搜索框为空
- **THEN** 返回所有片段

### Requirement: 终端选文创建片段

系统 SHALL 支持从终端选中文本直接创建片段。用户在终端中选中文本后，SHALL 能通过右键菜单或快捷键触发"创建片段"，选中文本预填到片段代码区。

#### Scenario: 终端选文创建片段

- **GIVEN** 用户在终端中选中了文本 "uptime && free -m"
- **WHEN** 用户右键选择"创建片段"
- **THEN** 系统打开新建片段表单，代码区预填 "uptime && free -m"，用户填写标题和标签后保存

#### Scenario: 无选中文本时禁用

- **GIVEN** 用户在终端中未选中任何文本
- **WHEN** 用户查看右键菜单
- **THEN** "创建片段"选项为禁用状态

### Requirement: 参数化模板

系统 SHALL 支持在片段代码中使用 `{{变量名}}` 语法定义模板变量。使用时 SHALL 提取变量列表、接受用户输入、展开模板并可选进行 shell 转义。

#### Scenario: 提取模板变量

- **GIVEN** 片段代码为 `ssh -p {{port}} {{user}}@{{host}}`
- **WHEN** 系统解析模板变量
- **THEN** 返回变量列表 `[port, user, host]`，去重并保持首次出现顺序

#### Scenario: 展开模板

- **GIVEN** 片段代码为 `ssh -p {{port}} {{user}}@{{host}}`，用户提供 `port=22, user=admin, host=prod1`
- **WHEN** 系统展开模板（shell 转义开启）
- **THEN** 返回 `ssh -p '22' 'admin'@'prod1'`

#### Scenario: 未定义变量报错

- **GIVEN** 片段代码包含 `{{unknown}}`
- **WHEN** 用户未提供 `unknown` 的值且无默认值
- **THEN** 系统返回错误，不展开模板

#### Scenario: 默认值回退

- **GIVEN** 片段代码包含 `{{port:22:SSH 端口}}`
- **WHEN** 用户未提供 `port` 的值
- **THEN** 使用默认值 `22` 展开
