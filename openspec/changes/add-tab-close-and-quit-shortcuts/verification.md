## 2026-09-15 当前验证记录

### 已通过

- `cargo test`：通过。核心单元测试 282、删除任务集成测试 8、fake-SSH 集成测试 72 均通过。
- `apple/Scripts/build-rust.sh`：通过，已重新生成 XCFramework 与 Swift 绑定。
- `xcodegen`：通过。
- `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build`：通过。
- `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`：通过；验证共享 Swift 源码和 FFI 可为 iOS 编译。
- 定向 XCTest：`QuitProtectionTests`、`TransferStoreTests`、`WorkspaceStoreTests` 中新增的停机用例通过，覆盖二次触发幂等、停止新任务、取消单文件和批量任务、关闭标签与拒绝新连接。

### 未通过 / 未完成

- 覆盖率门禁未通过：`cargo llvm-cov report` 为 lines 78.85%、regions 81.29%，低于项目要求的 95%。主要缺口在 FFI 的批量传输和导出层；不得据此归档。
- `cargo check --target x86_64-unknown-linux-gnu` 未执行成功：本机缺少 `x86_64-linux-gnu-gcc`，`aws-lc-sys` 无法交叉编译。此为工具链缺失，不是 Rust 源码诊断。
- 有签名 iOS 构建未通过：工程未配置开发团队；无签名编译已通过，但不能作为真机安装或发布验证。
- 尚未在真实运行的 macOS 应用与真实 SSH/SFTP 连接上手工验证二次 CMD+Q。远端中断后的最终执行状态按未知处理，不自动重放。

### 2026-09-15 手工验收反馈后的修正

- 手工验收发现旧实现按一次 CMD+Q 即退出。根因是系统终止请求绕过 SwiftUI `.onKeyPress`；该结论已由实际行为证伪。
- 已替换为 `NSApplicationDelegate.applicationShouldTerminate(_:)` 拦截，并新增单元测试覆盖“首次取消、第二次允许、重复请求不重复停机”。
- 修复后 `QuitProtectionTests` 与 macOS build 通过；仍需重新进行真实应用手工验收，且该项通过前不得归档。
