# 设计：消解基线冲突

## 1. 凭据存储统一

### 当前事实

- **specs**：`auth/spec.md` 第 23 行明确"保存的密码 MUST 存入本地凭据文件"；`credential-protection/spec.md` 支持本地凭据文件，可选加密（AES-256-GCM + Argon2），不依赖系统钥匙串。
- **实现**：`credentials.rs` 实现 `CredentialStore`，支持明文与加密两种格式，凭据文件位于配置目录。
- **AGENTS.md**：错误宣称"密码、私钥口令只存系统钥匙串"。

### 解决方案

修订 AGENTS.md 凭据相关段落，与 specs 对齐。

**原文**（AGENTS.md 约定段）：
> 安全红线：密码、私钥口令只存系统钥匙串（`kSecAttrSynchronizable`），配置 TOML 只存 `*_ref` 引用 key，不落密钥材料。

**修订为**：
> 安全红线：密码、私钥口令存入配置目录的专用凭据文件（`credentials.toml`），可选以用户设置的保护密钥加密（AES-256-GCM + Argon2）；主机配置 TOML 只存 `*_ref` 引用 key，不落密钥材料。系统钥匙串不参与凭据存储。

**影响**：
- 文档与实现一致
- 用户可选择明文或加密存储
- 不依赖 Apple 平台特性，跨平台一致

## 2. 连接池残留条款清理

### 当前事实

- **现行设计**（第 9–80 行）：显式连接所有权，终端/SFTP/后台传输各自独占 Socket，MUST NOT 隐式共享。
- **残留条款**（第 82–100 行）：连接复用，维护 `(host_id, credentials)` 缓存，优先复用已有 SshSession。
- **历史原因**：早期设计尝试复用，后因多 SSH 连接异常改为独占，但残留条款未从规格中清除。

### 解决方案

删除 `connection-pool/spec.md` 第 82–100 行「连接复用」章节（包括 Requirement 和三个 Scenario）。

**删除内容**：
```markdown
### Requirement: 连接复用

系统 SHALL 维护一个以 `(host_id, credentials)` 为键的连接缓存。对同一主机的后续操作优先复用缓存中已有的可用 `SshSession`，SHALL NOT 在无可用会话时直接新建连接。连接缓存 SHALL NOT 有空闲超时——连接持久存活，直到被显式断开或检测到失效。已打开终端页签的 shell 会话 SHALL 在用户切换到其他页签时保持存活，SHALL NOT 因 UI 视图切换被关闭或重新初始化。

#### Scenario: 复用已有会话执行 SFTP 列表
...

#### Scenario: 无可用会话时新建连接
...

#### Scenario: 切换 tab 后连接保持
...
```

**影响**：
- 规格与现行设计一致
- 巡检/批量任务按所有者独占设计，不恢复全局池

## 3. 片段状态澄清

### 当前事实

- **specs**：`snippets/spec.md` 标注"低优先级，预留"。
- **实现**：
  - Rust：`SnippetStore`（CRUD、Markdown 存储、标签）
  - FFI：`snippet_list`、`snippet_save`、`snippet_delete`
  - SwiftUI：`SnippetsView`（双栏布局、新建/编辑/删除、标签输入）

### 解决方案

修订 `snippets/spec.md`，区分已实现与待深化。

**修订 Purpose 段**：

**原文**：
> 代码片段能力（低优先级，预留）：以 Markdown 文件管理常用命令与脚本片段...

**修订为**：
> 代码片段能力（已实现基础能力，待深化）：以 Markdown 文件管理常用命令与脚本片段...

**新增章节**（在"Markdown 存储格式"之后、"预留约束"之前插入）：

```markdown
### 当前实现状态（2026-09-09 核对）

**已实现并验收**：
- 片段 CRUD（新建、查看、编辑、删除）
- Markdown 文件存储（标题、标签、说明、代码）
- 标签支持（平级字符串，逗号分隔）
- SwiftUI 双栏界面（列表 + 编辑）

**待深化**（路线图 5.2、5.7）：
- 多级标签（路径字符串 + `tags.toml` 索引）
- 终端选文 → 片段入口
- 片段搜索（标题、标签、内容）
- 参数化模板
```

**修订"预留约束"章节**：

**原文标题**：`### Requirement: 预留约束（低优先级）`

**修订为**：`### Requirement: 待深化能力约束`

**原文正文首句**：
> 本能力 SHALL 按低优先级预留：规格与设计先行，实现阶段不占用当前排期...

**修订为**：
> 本节仅适用于"待深化"能力（多级标签、终端选文、搜索、模板），已实现的基础能力（CRUD、Markdown 存储、标签、界面）不受此约束。待深化能力 SHALL 按低优先级推进：规格与设计先行，实现阶段不占用当前排期...

**影响**：
- 规格反映现状，避免重复建设
- 待深化能力明确范围

## 4. 修订清单

| 文件 | 修订内容 |
|------|----------|
| `AGENTS.md` | 凭据存储描述与 specs 对齐 |
| `openspec/specs/connection-pool/spec.md` | 删除第 82–100 行残留复用条款 |
| `openspec/specs/snippets/spec.md` | 修订 Purpose 段，新增"当前实现状态"章节，修订"预留约束"章节 |
| `openspec/brainstorming-ai-era-roadmap.md` | 1.3 冲突标记为已消解，#33 状态改为"已决" |

## 5. 验收方法

- 文档评审：对比修订前后，确认冲突消除
- 实现核对：确认 `credentials.rs` 与修订后的 AGENTS.md 一致
- 规格一致性：确认 `connection-pool/spec.md` 无残留条款，`snippets/spec.md` 反映现状
