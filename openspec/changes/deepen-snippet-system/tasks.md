# 任务：代码片段深化

## 前置条件

- [x] 基线冲突已消解（resolve-baseline-conflicts）
- [x] 现有 CRUD 已实现并验收（SnippetStore、FFI、SnippetsView）
- [x] 多级标签方案已决（路线图 5.7：路径字符串 + tags.toml 索引）
- [x] 标签分隔符已决（`/`）
- [x] 过滤默认逻辑已决（OR，可切换 AND）

## 任务清单

### T1. 多级标签核心（Rust）

#### T1.1 标签索引数据模型

- [ ] 在 `crates/panda-core/src/snippets.rs` 中新增 `TagMeta`、`TagNode`、`TagIndex` 结构体
- [ ] 实现 `TagIndex::rebuild_from(snippets)` 从片段列表重建派生树
- [ ] 实现 `TagIndex::tree()` 返回树形结构
- [ ] **测试**：空片段列表返回空树；单层标签正确分组；多层标签正确嵌套；同名前缀不误匹配（如"网络"不匹配"网络论"）

#### T1.2 标签过滤

- [ ] 新增 `TagFilter`、`TagFilterMode` 结构体
- [ ] 实现 `TagFilter::matches(snippet)` 支持 OR/AND 模式
- [ ] 实现子树匹配：`tag == prefix` 或 `tag.starts_with(prefix + "/")`
- [ ] **测试**：空选择返回全部；OR 模式匹配任一；AND 模式匹配全部；子树匹配正确；边界：标签为空、前缀完全匹配、大小写敏感

#### T1.3 `tags.toml` 持久化

- [ ] 实现 `TagIndex::load(path)` 从 TOML 文件加载元数据
- [ ] 实现 `TagIndex::save(path)` 保存元数据到 TOML 文件
- [ ] 实现 `TagIndex::merge(derived, saved)` 合并策略
- [ ] **测试**：文件不存在返回空索引；文件格式错误返回错误；合并时派生树为基础、saved 覆盖元数据；往返一致性

#### T1.4 标签重命名与删除

- [ ] 实现 `SnippetStore::rename_tag(old, new)` 级联更新所有片段
- [ ] 实现 `SnippetStore::remove_tag(path)` 从片段中移除标签
- [ ] **测试**：重命名精确匹配和子标签级联；删除只移除精确匹配；重命名后所有受影响片段的 frontmatter 正确更新；不存在的标签无操作

### T2. 片段搜索（Rust）

#### T2.1 搜索实现

- [ ] 在 `SnippetStore` 中新增 `search(query)` 方法
- [ ] 搜索范围：标题 + 标签 + 内容，大小写不敏感
- [ ] 多关键词 AND 语义（空格分隔）
- [ ] **测试**：空查询返回全部；单关键词匹配标题/标签/内容；多关键词 AND；无匹配返回空；特殊字符不崩溃

### T3. 参数化模板引擎（Rust）

#### T3.1 模板变量提取

- [ ] 新增 `crates/panda-core/src/snippet_template.rs`
- [ ] 实现 `extract_vars(code)` 解析 `{{name}}`、`{{name:default}}`、`{{name:default:描述}}`
- [ ] 去重，保持首次出现顺序
- [ ] **测试**：无变量返回空；单变量正确提取；多变量去重；默认值和描述正确解析；变量名非法字符不匹配；嵌套 `{{` 不崩溃

#### T3.2 模板展开

- [ ] 实现 `expand_template(code, values, shell_escape)` 替换变量
- [ ] 实现 `shell_escape(value)` 单引号转义策略
- [ ] 未提供值且无默认值时返回错误
- [ ] **测试**：正常替换；默认值回退；shell 转义正确（含单引号、双引号、空格、特殊字符）；未定义变量报错；空代码正常；变量名大小写敏感

### T4. FFI 绑定

#### T4.1 标签相关 FFI

- [ ] 新增 `TagNodeRecord` 结构体
- [ ] 导出 `list_snippet_tags()` 返回标签树
- [ ] 导出 `rename_snippet_tag(old, new)` 重命名标签
- [ ] 导出 `remove_snippet_tag(path)` 删除标签
- [ ] **测试**：FFI 层集成测试（通过 `cargo test`）

#### T4.2 搜索与过滤 FFI

- [ ] 导出 `search_snippets(query)` 搜索片段
- [ ] 导出 `filter_snippets(tags, mode)` 按标签过滤
- [ ] **测试**：FFI 层集成测试

#### T4.3 模板 FFI

- [ ] 新增 `TemplateVarRecord` 结构体
- [ ] 导出 `extract_snippet_template_vars(code)` 提取变量
- [ ] 导出 `expand_snippet_template(code, values, shell_escape)` 展开模板
- [ ] **测试**：FFI 层集成测试

### T5. SwiftUI 标签管理 UI

#### T5.1 标签树视图

- [ ] 在 `SnippetsView` 左侧列表上方新增标签树组件
- [ ] 标签树支持展开/折叠
- [ ] 点击标签过滤片段列表
- [ ] **测试**：Preview 验证（无自动化测试要求）

#### T5.2 过滤模式切换

- [ ] 标签树上方添加 OR/AND 切换按钮
- [ ] 切换后片段列表实时更新
- [ ] **测试**：Preview 验证

#### T5.3 标签管理面板

- [ ] 新增标签管理面板（创建/重命名/删除标签）
- [ ] 重命名标签时级联更新所有关联片段
- [ ] 删除标签时从所有片段中移除
- [ ] **测试**：Preview 验证 + 手动验证级联更新

#### T5.4 标签自动补全

- [ ] `SnippetEditSheet` 标签输入框支持自动补全
- [ ] 输入时从已有标签树匹配
- [ ] 支持 `/` 分隔的层级输入
- [ ] **测试**：Preview 验证

### T6. SwiftUI 搜索

#### T6.1 搜索框

- [ ] 在 `SnippetsView` 头部添加搜索框
- [ ] 输入关键词实时过滤片段列表
- [ ] 搜索范围：标题、标签、内容
- [ ] **测试**：Preview 验证

### T7. 终端选文 → 片段

#### T7.1 右键菜单入口

- [ ] 在终端视图右键菜单添加"创建片段"选项
- [ ] 获取 SwiftTerm `selectedText`
- [ ] 弹出 `SnippetEditSheet`，代码区预填选中文本
- [ ] 选中文本为空时禁用菜单项
- [ ] **测试**：手动验证

### T8. SwiftUI 模板变量填写

#### T8.1 模板变量表单

- [ ] 片段详情中检测 `{{变量}}`，显示"使用模板"按钮
- [ ] 点击后弹出变量填写表单
- [ ] 实时预览展开结果
- [ ] 确认后复制展开结果到剪贴板
- [ ] **测试**：Preview 验证

### T9. Swift 侧桥接

#### T9.1 AppBackend 扩展

- [ ] `AppBackend` 协议新增标签、搜索、模板相关方法
- [ ] `PandaCoreBackend` 实现调用 FFI
- [ ] `MockBackend` 实现内存模拟
- [ ] **测试**：MockBackend 单元测试

### T10. 集成测试与评审

#### T10.1 集成测试

- [ ] Rust 侧：标签索引 + 过滤 + 搜索 + 模板的端到端测试
- [ ] Swift 侧：AppModel 调用真实后端的集成测试
- [ ] 覆盖率检查：`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`

#### T10.2 评审与合并

- [ ] 提交 PR，附设计说明
- [ ] 评审通过后合并
- [ ] 归档变更提案
- [ ] 将 spec-deltas 合并回 `openspec/specs/snippets/spec.md`

## 依赖关系

```
T1（标签核心）──→ T4.1（标签 FFI）──→ T5（标签 UI）
T2（搜索）────→ T4.2（搜索 FFI）──→ T6（搜索 UI）
T3（模板）────→ T4.3（模板 FFI）──→ T8（模板 UI）
T7（终端选文）独立，无前置
T9（Swift 桥接）依赖 T4 全部完成
T10（集成测试）依赖 T5-T9 全部完成
```

T1、T2、T3、T7 可并行开发。

## 预估工作量

| 任务 | 预估 |
|------|------|
| T1 标签核心 | 8 小时 |
| T2 搜索 | 2 小时 |
| T3 模板引擎 | 4 小时 |
| T4 FFI 绑定 | 3 小时 |
| T5 标签 UI | 6 小时 |
| T6 搜索 UI | 2 小时 |
| T7 终端选文 | 2 小时 |
| T8 模板 UI | 4 小时 |
| T9 Swift 桥接 | 3 小时 |
| T10 集成测试 | 4 小时 |
| **总计** | 约 38 小时 |

## 风险

- T1.4 标签重命名级联更新需保证原子性，中途失败需可恢复
- T3.2 shell 转义需覆盖多种上下文，实现复杂度需控制
- T5 标签树 UI 在大量标签时的性能需验证
- T7 终端选文入口需确认 SwiftTerm `selectedText` 在所有平台版本可用
