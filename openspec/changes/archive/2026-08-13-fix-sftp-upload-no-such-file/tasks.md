## 1. SftpClient 递归目录创建能力

### 1.1 为 `SftpClient::create_dir_all` 编写失败测试

- [x] 1.1.1 编写测试：当远端父目录不存在时，`create_dir_all(path)` 应能递归创建所有父目录并返回成功（正常流程）
- [x] 1.1.2 编写测试：当目标目录已存在时，`create_dir_all(path)` 应返回成功（边界条件）
- [x] 1.1.3 编写测试：当远端根路径或关键父目录因权限不足无法创建时，`create_dir_all(path)` 应返回错误（意外操作）

### 1.2 实现 `SftpClient::create_dir_all`

- [x] 1.2.1 在 `crates/panda-core/src/sftp.rs` 的 `SftpClient` 上新增 `pub async fn create_dir_all(&self, path: &str) -> Result<()>`
- [x] 1.2.2 实现按 `/` 切分路径、逐层调用 `self.session.create_dir`，并忽略已存在目录的 `StatusCode::Failure`
- [x] 1.2.3 确保对绝对路径 `/a/b/c` 与相对路径 `a/b/c` 均能正确处理
- [x] 1.2.4 运行 `cargo test -p panda-core` 使新增测试通过

## 2. 批量上传目录创建语义修复

### 2.1 为批量上传目录创建语义编写失败测试

- [x] 2.1.1 编写测试：`execute_batch_upload` 上传本地目录到不存在的远端父目录时，应递归创建父目录并上传成功（正常流程）
- [x] 2.1.2 编写测试：`execute_batch_upload` 上传本地目录到远端已存在目录时，应视为成功并继续上传文件（边界条件）
- [x] 2.1.3 编写测试：`execute_batch_upload` 上传嵌套目录结构（`project/src/main.swift`）时，应创建所有中间目录并上传成功（正常流程）
- [x] 2.1.4 编写测试：当远端某层目录因权限无法创建时，`execute_batch_upload` 应记录包含源路径与目标路径的错误（意外操作）

### 2.2 修改 `execute_batch_upload` 目录创建逻辑

- [x] 2.2.1 在 `crates/panda-core/src/batch.rs` 中，将目录项处理从 `client.create_dir(&item.destination)` 改为 `client.create_dir_all(&item.destination)`
- [x] 2.2.2 调整错误收集格式为 `"{} -> {}: {}"`，包含 `item.source` 与 `item.destination`
- [x] 2.2.3 运行 `cargo test -p panda-core` 使新增测试通过

## 3. 批量下载错误信息格式统一

### 3.1 为批量下载错误信息格式编写失败测试

- [x] 3.1.1 编写测试：`execute_batch_download` 中某个文件下载失败时，错误信息应同时包含本地目标路径与远程源路径（意外操作）
- [x] 3.1.2 编写测试：`execute_batch_download` 中本地目录创建失败时，错误信息应同时包含远程源路径与本地目标路径（意外操作）

### 3.2 修改 `execute_batch_download` 错误信息格式

- [x] 3.2.1 在 `crates/panda-core/src/batch.rs` 中，将 `execute_batch_download` 的错误收集格式统一为 `"{} -> {}: {}"`
- [x] 3.2.2 运行 `cargo test -p panda-core` 使相关测试通过

## 4. FFI 集成测试

### 4.1 编写 FFI 批量上传目录集成测试

- [x] 4.1.1 在 `crates/panda-ffi/tests/ffi_fake_server.rs` 中新增测试：通过 `start_batch_upload` 上传本地目录到不存在的远端父目录，任务最终状态为 `Completed`（正常流程）
- [x] 4.1.2 新增测试：上传本地目录到远端已存在目录，任务最终状态为 `Completed`（边界条件）
- [x] 4.1.3 新增测试：上传含子目录的本地目录，远端目录结构与本地一致（正常流程，由 `ffi_batch_upload_directory_completes` 覆盖）
- [x] 4.1.4 运行 `cargo test -p panda-ffi` 使新增测试通过

## 5. 构建与覆盖率验证

- [x] 5.1 运行 `cargo build && cargo test` 确保 Rust 全 workspace 测试通过
- [x] 5.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 确保覆盖率达到门禁
- [x] 5.3 按顺序执行 `apple/Scripts/build-rust.sh` → `cd apple && xcodegen` → macOS/iOS 双端 `xcodebuild` 构建验证（改动涉及 FFI）
