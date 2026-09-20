## 1. 稳定标题的测试（Red）

- [x] 1.1 在 `panda-core` 为创建时标题分配添加失败测试：正常流程覆盖同主机连续创建；意外操作覆盖已有非连续后缀；边界覆盖无已有页签及多主机隔离。
- [x] 1.2 在 `panda-ffi` 为关闭页签后的标题稳定性添加失败测试：正常流程覆盖关闭首个页签；意外操作覆盖关闭中间页签；边界覆盖关闭后新建页签复用已释放序号。

## 2. 最小实现（Green）

- [x] 2.1 在 `panda-core` 实现平台无关的创建时标题分配规则，并让现有动态重编号测试改为稳定标题契约。
- [x] 2.2 在 `panda-ffi` 的工作区内存状态保存创建时标题，列表读取直接返回保存的标题；不改变 FFI 契约或 Swift 调用点。

## 3. 验证与规格同步

- [x] 3.1 运行受影响 Rust 单元测试，覆盖正常流程、意外操作和边界条件。
- [x] 3.2 运行 `cargo test` 与 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`；若环境或既有基线阻碍，记录明确结果且不误报通过。
- [x] 3.3 运行 `openspec validate stabilize-workspace-tab-titles --strict`，并在实现验收后将规范增量合并到 `openspec/specs/workspace/spec.md`、归档变更。
