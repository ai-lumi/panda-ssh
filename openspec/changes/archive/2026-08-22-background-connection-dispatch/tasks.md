## 1. 后台调度设施（red-green）

- [x] 1.1 先写失败测试：`FFIBackground.run` 在非主线程执行闭包且返回结果（断言闭包内 `Thread.isMainThread == false`，值正确回传）
- [x] 1.2 先写失败测试：`FFIBackground.run` 异常原样传播（断言抛出错误与闭包一致）
- [x] 1.3 实现：`PandaCoreBridge.swift` 新增 `FFIBackground`（`Task.detached(priority: .userInitiated)` 包装）

## 2. 连接建立异步化

- [x] 2.1 先写失败测试：`TerminalSessionStore.connect` 期间主线程不被占用（注入慢速 fake 连接，断言 connect 返回后主线程可继续执行 / `phase` 在后台完成后才更新为 `.shell`）
- [x] 2.2 先写失败测试：`SftpSessionStore.connect` 的 home 解析在后台执行（断言 `resolveSftpHomeDir` 闭包运行线程非主线程）
- [x] 2.3 实现：`PandaShellConnection` 拆分静态 `open(hostID:...) -> UInt64`；`TerminalSessionStore.connect` 经 `FFIBackground.run` 后台创建，回主线程组装
- [x] 2.4 实现：`SftpSessionStore.connect`/`resolveHomeDir` 经 `FFIBackground.run` 后台执行 `sftpHomeDir`

## 3. 传输网络操作异步化

- [x] 3.1 先写失败测试：`scanLocalBatch`/`scanRemoteBatch`、冲突预检、删除的调用在非主线程执行（handler 注入断言线程）
- [x] 3.2 实现：`SftpSessionStore` 的 `scanLocalItems`/`scanRemoteItems`/`checkUploadConflict`/`checkDownloadConflict`/`deleteRemoteCore` 包 `FFIBackground.run`

## 4. 回归与并行验证

- [x] 4.1 Swift 测试：两个连接同时建立互不等待（fake 连接各自 1s，断言总耗时显著小于 2s 或完成顺序与启动顺序无关）
- [x] 4.2 回归：macOS 全量 XCTest 通过；`cargo test` 全绿（Rust 零改动）
- [x] 4.3 `xcodegen` → macOS/iOS 双端 `xcodebuild` 通过
- [x] 4.4 spec 同步（delta 合并到 `openspec/specs/ffi-bridge/spec.md`）并归档变更