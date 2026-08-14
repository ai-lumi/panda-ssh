## Why

在 `transfer-tasks` 联调真实服务器（Synology DSM）过程中，暴露出若干 SFTP/侧栏/传输面板的 UX 与可测试性问题：

- App 硬编码远程根目录为 `/home/<username>`，在非标准 home 路径的服务器上导致 SFTP 列表失败，并被包装成误导性的「io 超时」。
- 侧栏主机行使用 `.onTapGesture(count: 2)` 拦截了 List 的单击选中事件，导致点击主机无高亮。
- 侧栏面包屑重复显示 rootTitle（如「远程 — ssh-test › 远程 — ssh-test」）。
- `WorkspaceView` 挂载常驻 100ms 传输轮询 Timer，即使无传输任务也持续调用 FFI 并触发 SwiftUI 重绘，造成 CPU/内存持续上涨。
- `panda-ffi` 的 `init_store` 使用进程级 `OnceLock`，同进程内无法重初始化，导致 `store_errors` 等多测试文件集成测试互相污染。
- 缺少针对真实 SSH/SFTP 服务器的自动化连通性测试，难以在回归阶段发现密钥/路径类问题。

## What Changes

- Rust `SftpClient` 新增 `home_dir()`，通过 `canonicalize(".")` 解析会话初始工作目录。
- FFI 新增 `sftp_home_dir(host_id, password, passphrase, trust_on_first_use)` 同步导出。
- Swift `SftpSessionStore.connect` 改为 async，连接 SFTP 时先解析真实 home 目录作为远程面板根目录。
- Swift `HostRowView` 的双击手势改用 `simultaneousGesture`，避免拦截 List 选中。
- Swift `SftpTabView.paneHead` 面包屑渲染跳过 rootTitle，消除重复。
- `TransferStore` 自行管理轮询 Timer：存在 running/queued 任务时启动，空闲时立即停止；`tick()` 列表无变化时不发布更新。
- `panda-ffi` 的 `STORES` 从 `OnceLock` 改为 `Mutex<Option<Arc<Stores>>>`，`init_store` 允许重新初始化。
- 新增 `crates/panda-core/tests/real_server.rs`，默认 `#[ignore]`，用于对 `lwq@100.78.247.105` 做 SSH exec 与 SFTP 上传/下载回归测试。

## Non-Goals

- 不新增传输限速、断点续传、目录递归传输。
- 不改主机密钥信任流程、不改 iCloud 同步策略。
- 真实服务器测试不纳入默认 `cargo test`（保持 `#[ignore]`）。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `sftp`: 远程面板根目录由运行时解析，不再硬编码 `/home/<username>`。
- `transfers`: 轮询由「常驻」改为「按需」，降低空转资源占用。
- `ffi-bridge`: `init_store` 语义放宽为「可重初始化」，App 仍只调用一次。

## Impact

- macOS/iPadOS 双端共享 SwiftUI 源码均受益。
- `panda-core` 新增 `SftpClient::home_dir`。
- `panda-ffi` 导出增加 `sftp_home_dir`；`init_store` 内部存储机制调整。
- Rust 测试：新增真实服务器集成测试；`store_errors` 等多测试文件可在同进程中稳定运行。
