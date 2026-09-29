## 1. Unix 权限测试

- [x] 1.1 先在 `panda-core` 添加 Unix 单元测试：首次保存凭据后，目标文件为 `0600`；覆盖正常保存。
- [x] 1.2 先在 `panda-core` 添加 Unix 单元测试：预置宽松权限的 `credentials.toml` 与遗留临时文件后保存，权限被收紧且内容/加密状态不变；覆盖意外状态。
- [x] 1.3 先在 `panda-ffi` 添加 Unix 集成或单元测试：`init_store` 创建并修复专属配置目录为 `0700`，同时修复已有凭据文件为 `0600`；覆盖新目录、既有目录及不存在凭据文件边界。
- [x] 1.4 添加或确认非 Unix 条件编译覆盖，保证不引用 Unix 专属 API 且保留既有保存语义。
- [x] 1.5 先添加 `panda-core` Unix 单元测试：固定旧临时文件为符号链接时，保存不得改写链接目标，并仍成功生成受限凭据文件。
- [x] 1.6 先添加 `panda-ffi` 平台条件测试：iPadOS 分支不修改 App Group 容器目录模式，而 macOS/Linux 专属目录仍收紧为 `0700`。

## 2. 凭据写入与初始化实现

- [x] 2.1 为 `CredentialStore` 实现专属私有原子写入路径：Unix 临时文件创建及首次写入前为 `0600`，成功后原子替换目标；不改变通用 `write_atomic` 的其他调用方。
- [x] 2.2 在 `init_store` 的 Unix 分支中将仅传入的 Panda SSH 专属配置目录收紧至 `0700`，并修复存在的 `credentials.toml` 为 `0600`；权限错误必须向调用方返回。
- [x] 2.3 补齐实现后的边界处理并运行格式化，确认不存在吞掉权限失败、泄露临时秘密或影响父目录的路径。
- [x] 2.4 将凭据临时文件改为不可预测名称和独占创建；不得跟随或复用固定旧临时文件的符号链接，并清理本次失败写入创建的临时文件。
- [x] 2.5 按平台区分目录权限：iPadOS App Group 容器不执行目录 chmod；其他 Unix 专属目录继续执行 `0700`，所有 Unix 目标仍修复凭据文件为 `0600`。

## 3. 验证与归档准备

- [x] 3.1 运行受影响的 `panda-core` 与 `panda-ffi` Rust 测试，确认正常、意外和边界权限场景全绿。
- [x] 3.2 运行 `cargo test` 及 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`，记录任何环境限制（当前沙箱禁止 fake-server 绑定本地回环端口；尚未获得完整全量测试与覆盖率结果）。
- [x] 3.3 在 Unix 目标执行 `cargo check`，并验证非 Unix/跨平台条件编译不引入构建回归。
- [x] 3.4 执行 `openspec validate harden-credential-file-permissions --strict`，通过后再进入实现与归档流程。
- [x] 3.5 运行新增符号链接与平台条件测试，并重新执行 OpenSpec 严格校验。
