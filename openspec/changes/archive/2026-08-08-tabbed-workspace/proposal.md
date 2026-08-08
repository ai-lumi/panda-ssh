## Why

当前 App 只有单一的主机列表与 SFTP 浏览视图，无法同时管理多个 SSH 会话。用户同时操作多台服务器时需要在终端与文件传输之间反复切换，效率低。多标签页工作区是 SSH 客户端的基础交互形态，也是后续分组、多会话能力的地基。

## What Changes

- 引入标签页工作区：一次可打开多个标签页，标签页类型为「终端」或「SFTP 文件浏览器」。
- 每个标签页关联一台服务器，维护独立的 SSH 会话生命周期（打开、断开、失败提示）。
- SFTP 标签页采用左本地、右远程的双栏布局。
- Rust 核心新增交互式 shell 通道能力（现有 FFI 仅支持一次性 `exec`），供终端标签页驱动。
- macOS 与 iPadOS 双端共享同一套 SwiftUI 标签页 UI 源码。

## Non-Goals

- 本变更不实现标签页拖拽拆分、标签分组、会话录制等高级特性。
- 本变更不实现终端配色方案、字体等外观自定义（沿用系统默认）。
- 本变更不改变 SFTP 上传/下载的传输逻辑（任务列表与进度条由 `transfer-tasks` 变更负责）。

## Capabilities

### New Capabilities

- `workspace`: 多标签页工作区，含终端/SFTP 两种标签页类型、标签页管理与会话生命周期。

### Modified Capabilities

None.

## Impact

- macOS 与 iPadOS 双端：标签页工作区 UI 为共享 SwiftUI 源码，双端同步获得；需要验证 iPadOS 上标签栏在紧凑布局下的可用性。
- Rust 核心（`crates/panda-core`）：新增交互式 shell 会话抽象（打开、读写、退出），复用现有 `SshSession` 认证链路。
- FFI（`crates/panda-ffi`）：新增 shell 通道的同步导出函数（`shell_open`/`shell_write`/`shell_read`/`shell_close`），继续遵循「导出函数同步、异步跑在全局 tokio runtime」的既有约定。
- Swift UI：新增工作区/标签页视图模型与 SwiftTerm 终端视图接线。
- 测试：core 侧 shell 会话的单元测试（fake/mock 通道），Swift 侧标签页状态机测试。
