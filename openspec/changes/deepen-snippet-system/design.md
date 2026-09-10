# 设计：代码片段深化

## 1. 多级路径标签系统

### 1.1 数据模型

#### 片段 frontmatter（不变）

现有 `tags: Vec<String>` 保持不变。每个标签字符串可包含 `/` 表示层级路径：

```yaml
tags: ["网络/内核参数", "故障处理/生产事故", "性能优化/延迟调优"]
```

**兼容性**：现有不含 `/` 的标签（如 `"deploy"`）视为一级标签，等价于 `"deploy"`。含 `/` 的旧标签（如用户曾手动输入 `"a/b"`）直接解释为层级路径，无需迁移。

#### `tags.toml` 索引文件

在片段存储目录下新增 `tags.toml`，存储标签的独立元数据：

```toml
[网络]
color = "#4A90D9"
description = "网络相关命令"

[网络/内核参数]
description = "TCP/IP 内核参数调整"

[故障处理]
color = "#E94E4E"

[故障处理/生产事故]
description = "生产环境故障处理流程"
```

**设计决策**：
- `tags.toml` 存储**独立元数据**（颜色、描述），不存储派生树结构
- 标签树可从所有片段的 frontmatter 重建（派生），丢失后重建不影响分类
- 颜色、描述为独立元数据，丢失后回退到默认值（无颜色、无描述）
- 空标签（没有任何片段使用）保留在 `tags.toml` 中，直到用户显式删除

#### Rust 数据模型扩展

```rust
// crates/panda-core/src/snippets.rs

/// 标签索引，管理标签元数据和派生树。
pub struct TagIndex {
    /// 标签路径 -> 元数据
    entries: BTreeMap<String, TagMeta>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TagMeta {
    /// 显示颜色（十六进制，如 "#4A90D9"）
    pub color: Option<String>,
    /// 标签描述
    pub description: Option<String>,
}

impl TagIndex {
    /// 从所有片段的标签集合重建派生树（不含元数据）。
    pub fn rebuild_from(snippets: &[Snippet]) -> Self { ... }

    /// 从 tags.toml 加载元数据。
    pub fn load(path: &Path) -> Result<Self> { ... }

    /// 保存到 tags.toml。
    pub fn save(&self, path: &Path) -> Result<()> { ... }

    /// 合并：以派生树为基础，叠加已保存的元数据。
    pub fn merge(derived: Self, saved: Self) -> Self { ... }

    /// 获取标签树结构（用于 UI 展示）。
    pub fn tree(&self) -> Vec<TagNode> { ... }

    /// 重命名标签（级联更新子标签）。
    pub fn rename(&mut self, old_path: &str, new_path: &str) -> Vec<(String, String)> { ... }

    /// 删除标签（不删除子标签，不删除片段）。
    pub fn remove(&mut self, path: &str) { ... }
}

/// 标签树节点。
pub struct TagNode {
    /// 标签名称（最后一级，如"内核参数"）
    pub name: String,
    /// 完整路径（如"网络/内核参数"）
    pub path: String,
    /// 子节点
    pub children: Vec<TagNode>,
    /// 元数据
    pub meta: TagMeta,
    /// 使用该标签的片段数量
    pub snippet_count: usize,
}
```

### 1.2 标签查询

```rust
/// 标签过滤模式。
pub enum TagFilterMode {
    /// OR：匹配任一标签即显示
    Any,
    /// AND：匹配全部标签才显示
    All,
}

/// 标签过滤器。
pub struct TagFilter {
    /// 选中的标签路径
    pub tags: Vec<String>,
    /// 过滤模式
    pub mode: TagFilterMode,
}

impl TagFilter {
    /// 判断片段是否匹配过滤条件。
    pub fn matches(&self, snippet: &Snippet) -> bool {
        if self.tags.is_empty() {
            return true; // 空选择显示全部
        }
        match self.mode {
            TagFilterMode::Any => self.tags.iter().any(|t| self.tag_matches(t, snippet)),
            TagFilterMode::All => self.tags.iter().all(|t| self.tag_matches(t, snippet)),
        }
    }

    /// 子树匹配：tag == prefix 或 tag.starts_with(prefix + "/")
    fn tag_matches(&self, prefix: &str, snippet: &Snippet) -> bool {
        snippet.tags.iter().any(|t| {
            t == prefix || t.starts_with(&format!("{}/", prefix))
        })
    }
}
```

**子树匹配规则**：选择"网络"标签时，匹配"网络"和"网络/内核参数"、"网络/TCP 调优"等所有子标签。选择"网络/内核参数"时，只匹配"网络/内核参数"及其子标签，不匹配"网络"。

### 1.3 标签重命名与级联更新

重命名标签需更新所有关联片段的 frontmatter：

```rust
impl SnippetStore {
    /// 重命名标签，级联更新所有关联片段。
    /// 返回受影响的片段名称列表。
    pub fn rename_tag(&self, old_path: &str, new_path: &str) -> Result<Vec<String>> {
        let mut affected = Vec::new();
        let mut snippets = self.list()?;
        for snippet in &mut snippets {
            let mut changed = false;
            for tag in &mut snippet.tags {
                if tag == old_path {
                    *tag = new_path.to_string();
                    changed = true;
                } else if tag.starts_with(&format!("{}/", old_path)) {
                    *tag = format!("{}/{}", new_path, &tag[old_path.len() + 1..]);
                    changed = true;
                }
            }
            if changed {
                self.save(snippet)?;
                affected.push(snippet.name.clone());
            }
        }
        Ok(affected)
    }

    /// 删除标签（仅从片段中移除该标签，不删除片段）。
    /// 子标签不受影响（它们成为独立标签）。
    pub fn remove_tag(&self, path: &str) -> Result<Vec<String>> {
        let mut affected = Vec::new();
        let mut snippets = self.list()?;
        for snippet in &mut snippets {
            let before = snippet.tags.len();
            snippet.tags.retain(|t| t != path);
            if snippet.tags.len() != before {
                self.save(snippet)?;
                affected.push(snippet.name.clone());
            }
        }
        Ok(affected)
    }
}
```

**原子性**：逐文件更新，如果中途失败，已更新的文件保持新值，未更新的文件保持旧值。恢复策略：提供 `rename_tag` 的逆操作（再调一次 `rename_tag(new, old)`）可回退已更新的部分。

### 1.4 FFI 扩展

```rust
// crates/panda-ffi/src/lib.rs

#[derive(Debug, Clone, uniffi::Record)]
pub struct TagNodeRecord {
    pub name: String,
    pub path: String,
    pub children: Vec<TagNodeRecord>,
    pub color: Option<String>,
    pub description: Option<String>,
    pub snippet_count: u32,
}

#[uniffi::export]
pub fn list_snippet_tags() -> Result<Vec<TagNodeRecord>, PandaError> { ... }

#[uniffi::export]
pub fn rename_snippet_tag(old_path: String, new_path: String) -> Result<Vec<String>, PandaError> { ... }

#[uniffi::export]
pub fn remove_snippet_tag(path: String) -> Result<Vec<String>, PandaError> { ... }

#[uniffi::export]
pub fn search_snippets(query: String) -> Result<Vec<SnippetRecord>, PandaError> { ... }

#[uniffi::export]
pub fn filter_snippets(tags: Vec<String>, mode: String) -> Result<Vec<SnippetRecord>, PandaError> { ... }
```

## 2. 片段搜索

### 2.1 搜索实现

在 `SnippetStore` 中新增搜索方法：

```rust
impl SnippetStore {
    /// 按关键词搜索片段。搜索标题、标签和内容。
    /// 大小写不敏感。
    pub fn search(&self, query: &str) -> Result<Vec<Snippet>> {
        if query.trim().is_empty() {
            return self.list();
        }
        let query_lower = query.to_lowercase();
        let keywords: Vec<&str> = query_lower.split_whitespace().collect();
        let mut results = Vec::new();
        for snippet in self.list()? {
            let haystack = format!(
                "{} {} {}",
                snippet.title.to_lowercase(),
                snippet.tags.join(" ").to_lowercase(),
                snippet.body.to_lowercase()
            );
            if keywords.iter().all(|kw| haystack.contains(kw)) {
                results.push(snippet);
            }
        }
        Ok(results)
    }
}
```

**搜索语义**：多个空格分隔的关键词为 AND 关系（所有关键词都必须匹配）。搜索范围为标题、标签和内容的并集。

### 2.2 FFI 导出

```rust
#[uniffi::export]
pub fn search_snippets(query: String) -> Result<Vec<SnippetRecord>, PandaError> {
    Ok(snippet_store()?.search(&query)?.into_iter().map(SnippetRecord::from).collect())
}
```

## 3. 终端选文 → 片段

### 3.1 交互流程

1. 用户在终端中选中文本（SwiftTerm `selectedText`）
2. 右键菜单或快捷键触发"创建片段"
3. 弹出 `SnippetEditSheet`，代码区预填选中文本
4. 用户填写标题、标签后保存

### 3.2 实现位置

- **Swift 侧**：在终端视图的右键菜单中添加"创建片段"选项
- **SwiftTerm**：`selectedText` 属性获取选中文本
- **不涉及 Rust 变更**：现有 FFI `save_snippet` 已满足需求

### 3.3 边界

- 选中文本为空时禁用菜单项
- 预填内容不自动保存，用户需确认标题和标签
- 不自动连接到任何主机（片段与主机无关）

## 4. 参数化模板引擎

### 4.1 模板语法

使用 `{{变量名}}` 语法：

```bash
# 片段代码
ssh -p {{port}} {{user}}@{{host}} "uptime && free -m"
```

**变量命名规则**：`[a-zA-Z_][a-zA-Z0-9_]*`，不允许空格或特殊字符。

### 4.2 模板解析与展开

```rust
// crates/panda-core/src/snippet_template.rs

/// 模板变量定义。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateVar {
    /// 变量名
    pub name: String,
    /// 默认值（可选）
    pub default: Option<String>,
    /// 描述（可选）
    pub description: Option<String>,
}

/// 解析片段代码中的模板变量。
pub fn extract_vars(code: &str) -> Vec<TemplateVar> {
    // 正则匹配 {{name}} 或 {{name:default}} 或 {{name:default:描述}}
    // 去重，保持首次出现顺序
}

/// 展开模板，替换变量为实际值。
/// `values` 为用户提供的变量值。
/// `shell_escape` 控制是否对值进行 shell 转义。
pub fn expand_template(
    code: &str,
    values: &HashMap<String, String>,
    shell_escape: bool,
) -> Result<String, TemplateError> {
    // 替换 {{name}} 为 values[name]
    // 如果 shell_escape=true，对值进行 shell 转义
    // 未提供值的变量使用默认值，无默认值则报错
}
```

### 4.3 Shell 转义

```rust
/// Shell 转义：将值用单引号包裹，内部单引号用 `'\''` 替换。
pub fn shell_escape(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
```

**转义策略**：统一使用单引号包裹。单引号内的所有字符都是字面量，只有单引号本身需要特殊处理（`'\''`：结束单引号、转义单引号、重新开始单引号）。

### 4.4 模板变量来源

- 用户手动输入（展开前弹窗填写）
- 后续可从主机配置自动填充（如 `{{host}}` 自动取当前连接主机名），但本提案不实现，留给批量执行提案

### 4.5 FFI 扩展

```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct TemplateVarRecord {
    pub name: String,
    pub default: Option<String>,
    pub description: Option<String>,
}

#[uniffi::export]
pub fn extract_snippet_template_vars(code: String) -> Result<Vec<TemplateVarRecord>, PandaError> { ... }

#[uniffi::export]
pub fn expand_snippet_template(
    code: String,
    values: Vec<(String, String)>,
    shell_escape: bool,
) -> Result<String, PandaError> { ... }
```

## 5. UI 设计

### 5.1 标签管理 UI

在 `SnippetsView` 左侧列表上方添加标签树视图：

```
┌─────────────────────────────────────────────┐
│ [搜索框]                                     │
├──────────┬──────────────────────────────────┤
│ 标签树    │  片段列表                         │
│          │                                  │
│ ▼ 网络    │  ○ 片段A  [网络/内核参数]          │
│   内核参数 │  ○ 片段B  [网络/TCP调优]          │
│   TCP调优 │                                  │
│ ▼ 故障处理 │                                  │
│   生产事故 │                                  │
│   性能优化 │                                  │
│     延迟  │                                  │
│          │                                  │
│ [管理标签] │                                  │
├──────────┴──────────────────────────────────┤
│ 片段详情 / 编辑                               │
└─────────────────────────────────────────────┘
```

- 点击标签过滤片段列表（默认 OR）
- 右键标签可重命名/删除
- "管理标签"按钮打开标签管理面板（批量操作、设置颜色/描述）
- 搜索框输入关键词实时过滤

### 5.2 过滤模式切换

在标签树上方添加 OR/AND 切换按钮：
- 默认 OR：匹配任一选中标签
- 切换 AND：匹配全部选中标签

### 5.3 标签自动补全

在 `SnippetEditSheet` 的标签输入框中：
- 输入时从已有标签树自动补全
- 支持 `/` 分隔的层级输入
- 新建标签直接输入即可

### 5.4 模板变量填写

点击"使用模板"时：
1. 解析代码中的 `{{变量}}`
2. 弹出变量填写表单（变量名、描述、默认值预填）
3. 实时预览展开结果
4. 确认后复制展开结果到剪贴板

## 6. 迁移方案

### 6.1 现有数据兼容

- **标签**：现有 `tags: Vec<String>` 无需迁移。不含 `/` 的标签视为一级标签；含 `/` 的标签直接解释为层级路径。
- **`tags.toml`**：首次启动时不存在，从片段 frontmatter 重建派生树。后续用户设置的颜色/描述保存到 `tags.toml`。

### 6.2 迁移步骤

无需显式迁移步骤。首次加载时：
1. `TagIndex::rebuild_from(snippets)` 从所有片段重建派生树
2. 尝试加载 `tags.toml`，不存在则使用空元数据
3. 合并：`TagIndex::merge(derived, saved)` 以派生树为基础，叠加已保存的元数据

### 6.3 边界情况

- 空标签（没有任何片段使用）：在标签树中显示为灰色，用户可删除
- 同名冲突：标签路径区分大小写，`网络` 和 `Network` 为不同标签
- 最大层级：不限制，但 UI 展示超过 5 级时缩进截断

## 7. 架构分层

| 层 | 职责 |
|----|------|
| `panda-core` | 标签索引、查询过滤、搜索、模板解析/展开、标签重命名级联 |
| `panda-ffi` | 导出标签树、搜索、过滤、模板变量提取/展开接口 |
| SwiftUI | 标签树 UI、搜索框、过滤模式切换、终端选文入口、模板变量填写表单 |

业务逻辑（标签匹配规则、搜索语义、模板展开、shell 转义）全部在 Rust 核心。Swift 侧只负责 UI 渲染和用户交互。
