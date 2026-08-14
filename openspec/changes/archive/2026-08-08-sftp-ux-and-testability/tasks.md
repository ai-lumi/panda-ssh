## 1. SFTP 根目录自动解析

- [x] 1.1 Rust 核心：新增 `SftpClient::home_dir()`，使用 `canonicalize(".")` 解析会话初始工作目录。
- [x] 1.2 FFI：新增 `sftp_home_dir` 同步导出。
- [x] 1.3 Swift 桥接：新增 `PandaCoreBridge.resolveSftpHomeDir(of:...)`。
- [x] 1.4 Swift UI：`SftpSessionStore.connect` 改为 async，使用解析到的路径作为远程面板根目录。

## 2. 侧栏交互修复

- [x] 2.1 主机行：双击打开终端改为 `simultaneousGesture`，避免拦截 List 单击选中。
- [x] 2.2 面包屑：`SftpTabView.paneHead` 跳过 rootTitle，消除重复显示。

## 3. 传输轮询资源优化

- [x] 3.1 `TransferStore` 自行管理 100ms Timer，仅在存在 running/queued 任务时启动。
- [x] 3.2 `tick()` 在任务列表无变化时不赋值 `tasks`，避免空转触发 SwiftUI 重绘。

## 4. `init_store` 可测试化

- [x] 4.1 将 `STORES` 从 `OnceLock` 改为 `Mutex<Option<Arc<Stores>>>`。
- [x] 4.2 `init_store` 允许重新初始化，`stores()` 返回 `Arc<Stores>`。
- [x] 4.3 确认 `panda-ffi` 集成测试（含 `store_errors`）在同进程中稳定通过。

## 5. 真实服务器回归测试

- [x] 5.1 新增 `crates/panda-core/tests/real_server.rs`，覆盖 SSH exec、SFTP home 解析、列表、上传/下载 round-trip。
- [x] 5.2 测试默认 `#[ignore]`，私钥路径可通过 `PANDA_SSH_TEST_KEY` 覆盖。

## 6. 验证

- [x] 6.1 `cargo test` 全绿。
- [x] 6.2 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过。
- [x] 6.3 `build-rust.sh` → `xcodegen` → macOS / iOS 模拟器 `xcodebuild test` 通过。
- [x] 6.4 App 手动验证：SFTP 可正常打开 Synology home 目录、主机可单击选中、空转 CPU/内存稳定。

## 7. 归档

- [x] 7.1 更新 `openspec/specs/ffi-bridge/spec.md` 中 `init_store` 语义。
- [x] 7.2 `openspec validate sftp-ux-and-testability --strict` 通过。
- [x] 7.3 归档本变更。
