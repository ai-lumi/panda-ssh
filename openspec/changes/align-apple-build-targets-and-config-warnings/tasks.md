## 1. RED 基线与归档回归测试

- [x] 1.1 使用当前 Apple 构建与 Xcode 链接流程记录 RED 基线，确认输出包含 Rust 静态库的 macOS deployment target 不匹配、两处 `UnsafeBufferPointer` 悬垂缓冲区和一处未使用变量诊断。
- [x] 1.2 在 `apple/PandaSSHTests/ConfigExportImportTests.swift` 中先补充 ZIP local file header 字节序回归测试：正常的非空条目、异常的损坏归档拒绝路径，以及零长度条目的边界字段；运行专项 XCTest 并确认既有 ZIP 二进制格式受保护。

## 2. 消除 Swift 编译器警告

- [x] 2.1 在 `apple/PandaSSH/Config/ConfigArchiveUtility.swift` 中以 `withUnsafeBytes` 约束 `UInt16` 与 `UInt32` 小端字节缓冲区生命周期，不改变 ZIP 字段编码。
- [x] 2.2 在 `apple/PandaSSH/Config/ConfigImporter.swift` 的备份循环中显式忽略未使用的 ZIP 条目名称，保留写入循环对条目名称的使用。
- [x] 2.3 运行配置导入导出专项 XCTest，确认正常导出导入、损坏归档拒绝和零长度条目边界测试均通过，且 Swift 编译输出不再包含三项警告。

## 3. 对齐 Apple Rust 构建目标

- [x] 3.1 修改 `apple/Scripts/build-rust.sh`，为 macOS Darwin target 的单次 Cargo 调用设置 `MACOSX_DEPLOYMENT_TARGET=14.0`，为 iOS 与 iOS Simulator target 的单次调用设置 `IPHONEOS_DEPLOYMENT_TARGET=17.0`，且不修改 `apple/project.yml` 的 App 最低版本。
- [x] 3.2 完整运行 `apple/Scripts/build-rust.sh` 重建忽略的 XCFramework，并确认四个 Apple target 均成功完成且 Cargo 构建参数未跨平台泄漏。

## 4. 端到端验证

- [x] 4.1 运行 XcodeGen 后分别构建 macOS 与 iPadOS target，确认链接输出不再包含”built for newer 'macOS' version”及三项 Swift 编译器警告。
- [x] 4.2 运行相关 Swift XCTest、`cargo test` 和 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`，确认所有测试通过且 lines 与 regions 覆盖率均不少于 95%。
- [x] 4.3 执行 `openspec validate align-apple-build-targets-and-config-warnings --type change --strict`，确认变更工件一致且可进入实现阶段。
