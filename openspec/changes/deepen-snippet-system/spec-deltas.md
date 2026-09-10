# Spec Deltas：代码片段深化

## 变更概览

本提案对 `openspec/specs/snippets/spec.md` 进行增量更新，新增多级标签、搜索、模板引擎和终端选文入口的规格条目。现有 CRUD、存储路径和 Markdown 格式规格保持不变。

---

## 1. snippets/spec.md

### 1.1 修订 Purpose 段

**原文**：
> 代码片段能力（低优先级，预留）：以 Markdown 文件管理常用命令与脚本片段，支持选择存储路径，便于用户复用与手工维护。

**修订为**：
> 代码片段能力（已实现基础能力，深化中）：以 Markdown 文件管理常用命令与脚本片段，支持多级标签分类、全文搜索、参数化模板与终端选文入口，便于用户复用与手工维护。

### 1.2 新增 Requirement：多级标签

在"Markdown 存储格式"之后新增：

```markdown
### Requirement: 多级标签

系统 SHALL 支持多级路径标签，使用 `/` 作为层级分隔符。每个片段可挂多个标签，标签本身具有层级结构。标签索引 SHALL 以 `tags.toml` 文件存储于片段存储目录，保存标签的独立元数据（颜色、描述）。标签树可从所有片段的 frontmatter 重建。

#### Scenario: 片段挂多级标签

- **GIVEN** 用户创建一个片段
- **WHEN** 用户设置标签为 `["网络/内核参数", "故障处理/生产事故"]`
- **THEN** 系统在前线 matter 中保存路径字符串，标签树中"网络"下显示子标签"内核参数"

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
```

### 1.3 新增 Requirement：标签管理

```markdown
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
```

### 1.4 新增 Requirement：片段搜索

```markdown
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
```

### 1.5 新增 Requirement：终端选文创建片段

```markdown
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
```

### 1.6 新增 Requirement：参数化模板

```markdown
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
```

### 1.7 修订"预留约束"章节

**原标题**：`### Requirement: 预留约束（低优先级）`

**修订为**：`### Requirement: 深化能力约束`

**原文正文首句**：
> 本能力 SHALL 按低优先级预留：规格与设计先行，实现阶段不占用当前排期，MUST NOT 阻塞其它能力的开发与交付。

**修订为**：
> 本节适用于多级标签、标签管理、搜索、终端选文、参数化模板等深化能力。已实现的基础能力（CRUD、Markdown 存储、平级标签、界面）不受此约束。深化能力 SHALL 按优先级推进：规格与设计先行，实现阶段不占用当前排期，MUST NOT 阻塞其它能力的开发与交付。

---

## 2. 新增文件：tags.toml 格式规格

在 `openspec/specs/snippets/` 目录下新增 `tags-format.md`：

```markdown
# tags.toml 格式规格

## Purpose

定义片段标签索引文件格式。

## 格式

`tags.toml` 位于片段存储目录根，使用 TOML 格式：

\`\`\`toml
[网络]
color = "#4A90D9"
description = "网络相关命令"

[网络/内核参数]
description = "TCP/IP 内核参数调整"
\`\`\`

## 字段

- **key**：标签完整路径（如 `网络/内核参数`）
- **color**（可选）：十六进制颜色字符串
- **description**（可选）：标签描述文本

## 约束

- 文件可选，不存在时从片段 frontmatter 重建派生树
- 元数据（颜色、描述）丢失后回退到默认值
- 文件编码 MUST 为 UTF-8
```

---

## 影响分析

### 兼容性

- **标签**：现有平级标签无需迁移，含 `/` 的旧标签直接解释为层级路径
- **搜索**：新增能力，不影响现有行为
- **模板**：新增能力，不含 `{{}}` 的片段代码不受影响
- **终端选文**：新增入口，不影响现有终端行为
- **`tags.toml`**：新增文件，不影响现有 Markdown 片段文件

### 测试影响

- Rust 侧新增标签索引、过滤、搜索、模板的单元测试
- FFI 层新增集成测试
- Swift 侧 MockBackend 需更新
- 覆盖率门禁：所有新增代码分支 >= 95%

### 文档影响

- `snippets/spec.md` 新增 5 个 Requirement 章节
- 新增 `tags-format.md` 规格文件
- 路线图 5.2 的待深化能力标记为"设计中"

---

## 迁移指南

### 现有用户数据

无需显式迁移。首次加载时：
1. 从所有片段 frontmatter 重建标签派生树
2. `tags.toml` 不存在时使用空元数据
3. 用户后续设置的标签颜色/描述保存到 `tags.toml`

### 开发者影响

- `SnippetStore` API 新增 `search`、`rename_tag`、`remove_tag` 方法
- FFI 新增 6 个导出函数
- `AppBackend` 协议新增标签、搜索、模板相关方法
- `MockBackend` 需同步更新
