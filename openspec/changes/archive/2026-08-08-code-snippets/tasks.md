## 1. 片段存储（Rust 核心）

- [x] 1.1 先写测试：frontmatter + 正文的 Markdown 解析/写入 round-trip。
- [x] 1.2 实现 `SnippetStore`：目录扫描、`*.md` 解析（含非法 frontmatter 兜底）、原子写入。
- [x] 1.3 先写测试：删除、重命名（title 变更）、标签缺失兜底。

## 2. FFI

- [x] 2.1 先写测试：`init_snippets`/`list_snippets`/`save_snippet`/`delete_snippet` 的 store 行为与未初始化报错。
- [x] 2.2 实现上述同步导出，维持全局 runtime 约定。

## 3. Swift UI（macOS/iPadOS 共享源码）

- [x] 3.1 先写测试：片段列表模型与目录选择状态。
- [x] 3.2 实现片段列表、编辑、删除、复制与存储目录设置。

## 4. 验证

- [x] 4.1 `cargo test` 全绿；双端构建通过。

## 5. 质量门禁

- [x] 5.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 5.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。
