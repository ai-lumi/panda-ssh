## Why

SFTP 界面上传本地目录时，Swift 层与 Rust 批量扫描器各自追加了一次顶层目录名，导致远端路径出现重复层级。该行为违反目录上传保持本地结构的既有预期，且会将用户文件写入错误位置。

## What Changes

- 修正 SFTP 目录上传的调用边界：Swift 仅将当前远端目录传给本地批量扫描器，由扫描器追加本地顶层目录名一次。
- 为包含中文目录名和文件名的目录上传增加回归测试，确保顶层目录名不重复且嵌套结构保持不变。
- 保持单文件上传、多选文件上传、Rust 扫描器和 FFI 契约不变。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `sftp-transfer`: 明确从 SFTP 界面上传本地目录时，当前远端目录与本地顶层目录名只能各参与一次目标路径拼接。

## Impact

- 受影响代码：`apple/PandaSSH/Workspace/SftpSessionStore.swift` 与对应 XCTest。
- macOS 与 iPadOS 共用同一 SwiftUI 会话层，修复将同时生效。
- 不修改 Rust 核心、FFI 公开接口、网络协议、依赖或密钥处理。

## Non-goals

- 不调整批量上传的远端目录创建语义。
- 不改变下载路径、多选文件上传、冲突处理或任务组展示。
