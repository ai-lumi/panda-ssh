## Context

用户需要一个简单的「命令收藏」：保存常用命令/脚本，按需查看与复制。存储采用纯 Markdown 文件而非数据库，理由：可读、可手工编辑、可纳入用户的 iCloud Drive / Git 版本管理、与「极简、可迁移」的产品定位一致。本变更当前仅预留设计，不实现。

## Goals / Non-Goals

**Goals:**

- 片段 = 一个独立 `.md` 文件，含 YAML frontmatter（标题、标签、创建时间）与正文（说明 + 代码块）。
- 存储目录可由用户选择，目录内其它 `.md` 文件可作为片段导入。
- core 层纯文件操作，平台无关，未来 Linux/Windows 可复用。

**Non-Goals:**

- 本轮实现（预留，待启动）。
- 云端同步、共享市场、模板变量。
- 终端一键执行（依赖 `tabbed-workspace` 的 shell 通道，后续单独变更）。
- 富文本编辑器与语法高亮补全（正文用 plain 代码块即可）。

## Decisions

### 文件格式：frontmatter + 正文

每个片段文件格式：

```markdown
---
title: 部署 release 分支
tags: [deploy, git]
---
## 说明
将 release 分支部署到生产服务器。

## 代码
```bash
ssh deploy@prod 'cd /srv/app && git pull origin release && systemctl restart app'
```
```

解析器读取 frontmatter（`title`/`tags`，缺失时用文件名兜底）与正文；写入时原子写（temp + rename），沿用 core 现有风格。

### 存储目录注入

Swift 侧在设置页选择目录（macOS `NSOpenPanel`；iPadOS `UIDocumentPicker` + 必要时拷贝入 App Group 容器），通过 `init_snippets(dir)` 注入 Rust core；目录变更后旧引用失效，需重新初始化。

### FFI 接口（预留签名）

- `init_snippets(dir: String)`
- `list_snippets() -> Vec<SnippetRecord>`
- `save_snippet(snippet: SnippetRecord)`（title 变更时负责文件重命名）
- `delete_snippet(name: String)`

## Risks / Trade-offs

- [用户手工编辑片段文件导致格式损坏] → 解析器对非法 frontmatter 降级为文件名兜底，不报错崩溃。
- [目录内存在大量非片段 `.md` 文件] → 仅解析含合法 frontmatter 的文件，其余忽略。
- [文件名冲突] → 以文件名+标题双关键标识，冲突时提示改名。

## Migration Plan

无需迁移（全新能力）。实现时若需从旧格式导入，另行评估。

## Open Questions

- 片段是否需要文件夹分类？先用 frontmatter `tags` 做轻量分类，避免目录结构复杂化。
