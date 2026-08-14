## Why

Panda SSH 在运行过程中会产生各种错误（连接失败、传输异常、配置同步冲突、主机密钥变更等），但这些错误目前仅通过 Toast 短暂提示或内联错误文案展示，用户无法回溯历史。需要一个持久化的运行时日志系统，让用户（和开发者）可以查看完整的运行时事件流，便于排查问题。

## What Changes

- 新增 Swift 侧 `Logger` 模块：全局单例，支持 debug/info/warning/error 四级日志
- 新增内存环形缓冲区：最多保留 1000 条日志，供 UI 即时展示
- 新增文件日志：写入 `~/.panda-ssh/logs/panda-ssh.log`（macOS）/ App Group 容器（iPadOS），文件达到 100MB 时自动轮转
- 新增 UI 日志窗口：macOS 通过菜单栏打开独立日志窗口；iPadOS 通过侧栏入口切换到日志页
- 在关键错误路径接入日志调用：连接失败、传输异常、配置同步、主机密钥、FFI 错误等
- 日志格式：`[时间戳] [级别] [模块] 消息`

## Non-goals

- Rust 侧 tracing 日志桥接到 Swift：当前 Rust 侧未使用 tracing，本期不引入。Rust 侧错误已通过 FFI 错误枚举传递到 Swift，由 Swift 侧统一记录
- 远程日志收集/崩溃上报：本期仅本地日志，不做云端上报
- 日志导出功能：用户可通过 Finder/文件 App 直接访问日志文件，不在 App 内提供导出按钮
- 日志过滤/搜索：首期仅按级别着色与自动滚动，不做搜索与高级过滤

## Capabilities

### New Capabilities

- `runtime-logging`: 运行时日志记录与展示——内存环形缓冲区（1000 条）、文件日志（100MB 轮转）、UI 日志窗口

### Modified Capabilities

无。本变更新增独立的日志能力，不改变已有 spec 的行为。

## Impact

- **新增文件**：`apple/PandaSSH/Logging/Logger.swift`（日志核心）、`apple/PandaSSH/Logging/LogView.swift`（日志窗口 UI）
- **修改文件**：
  - `apple/PandaSSH/PandaSSHApp.swift` — 注入 Logger 环境对象、macOS 新增日志窗口 Scene
  - `apple/PandaSSH/Workspace/TerminalSessionStore.swift` — 连接失败时记日志
  - `apple/PandaSSH/Workspace/SftpSessionStore.swift` — SFTP 操作失败时记日志
  - `apple/PandaSSH/Workspace/TransferStore.swift` — 传输任务失败时记日志
  - `apple/PandaSSH/Workspace/ConnectionGate.swift` — TOFU/密钥变更/密码缺失时记日志
  - `apple/PandaSSH/PandaCoreBackend.swift` — FFI 调用失败时记日志
  - `apple/PandaSSH/Sync/ConfigSync.swift` — 同步冲突时记日志
  - `apple/PandaSSH/SidebarView.swift` — iPadOS 侧栏新增日志入口
- **macOS 影响**：新增 `WindowGroup` scene 用于日志窗口（菜单栏「窗口 → 日志」或快捷键 ⌘⇧L）
- **iPadOS 影响**：侧栏底部新增「日志」入口，切换到全屏日志页
- **依赖**：无新增第三方依赖，纯 Swift 标准库 + SwiftUI 实现
- **测试**：Logger 的环形缓冲区、文件轮转、级别过滤用 XCTest 覆盖
