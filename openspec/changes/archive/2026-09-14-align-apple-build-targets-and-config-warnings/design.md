## Context

见 `proposal.md` 的动机说明。XcodeGen 在 `apple/project.yml` 中将 App 的最低部署目标声明为 macOS 14.0 与 iOS 17.0，但 `apple/Scripts/build-rust.sh` 直接调用 Cargo，未向 Rust Apple target 传递对应部署目标。当前工具链因此用本机 SDK 的较新 macOS 版本标记静态库对象。

`ConfigArchiveUtility` 以局部整数变量的地址构造 `UnsafeBufferPointer` 来写入 ZIP 小端字段。尽管数据会立即追加，Swift 编译器仍无法证明该指针不会在局部变量生命周期结束后被使用。`ConfigImporter` 的备份循环只依赖目标文件名，却绑定了 ZIP 条目名称。

## Goals / Non-Goals

**Goals:**

- 使 Rust 构建产物的 Apple 最低部署目标与 Xcode App target 一致。
- 在保持 ZIP STORE 格式、小端编码和 `.pandassh` 兼容性的同时消除 Swift 指针生命周期警告。
- 移除未使用变量警告，并以专项测试与全量构建输出验证修复。

**Non-Goals:**

- 不修改 XcodeGen 中的 macOS 14.0 或 iOS 17.0 最低版本。
- 不调整 ZIP 解析、导入备份、配置文件内容或公开 FFI 契约。
- 不提交生成的 XCFramework，亦不引入构建依赖或 CI 流程重构。

## Decisions

### 1. 在每次 Cargo Apple 构建调用中按 target 注入部署目标

`build-rust.sh` 将为 Darwin target 的 Cargo 调用设置 `MACOSX_DEPLOYMENT_TARGET=14.0`，并为 iOS 与 iOS Simulator target 的 Cargo 调用设置 `IPHONEOS_DEPLOYMENT_TARGET=17.0`。环境变量仅作用于对应的单次命令，不作脚本级全局导出。

这样，静态库对象与 Xcode 链接阶段使用的最低版本一致，同时不会将 macOS 设置泄漏到 iOS 构建或反向泄漏。脚本是本地与 Release CI 的共同入口，因此不需要在工作流中重复传递变量。

备选方案：

- 将 App 的 macOS 最低版本提高至 SDK 默认版本：拒绝，因为会放弃现有 macOS 14.0 兼容性。
- 只在 CI 设置环境变量：拒绝，因为开发机仍会生成不兼容产物。
- 在 Cargo 配置中全局设置：拒绝，因为该值是 Apple App 交付约束，应与脚本中具体 target 的构建命令保持邻近且可见。

### 2. 使用 `withUnsafeBytes` 限定 ZIP 字段缓冲区生命周期

`Data.append(u16:)` 与 `Data.append(u32:)` 将先取得小端整数，再在 `withUnsafeBytes(of:)` 的同步闭包内把原始字节追加到 `Data`。该闭包边界向编译器和读者保证缓冲区不会逃逸。

备选方案：

- 保留 `UnsafeBufferPointer(start: &value, count: 1)`：拒绝，因为会持续触发悬垂指针诊断。
- 通过临时 `Data` 分配来复制字节：拒绝，因为不需要额外分配，且闭包化原始字节访问已能精确表达所有权与生命周期。

### 3. 用原始 ZIP 头字段断言保护二进制格式

在现有 `ConfigExportImportTests` 中创建固定长度与文件名的临时输入，调用 `ConfigArchiveUtility.createZip`，并断言首个 local file header 中的 `UInt16` 和 `UInt32` 长度字段为预期的小端字节序。该测试不依赖内部指针实现，保护现有 ZIP 字节格式。

编译器诊断本身是本次警告修复的 RED 验收：修改前的 Swift 构建会报告两处悬垂指针与一处未使用变量警告；实现后，同一构建输出不得包含这三条诊断。字节序测试则确保仅重写内存访问方式不会改变已存在的归档行为。

### 4. 对仅需目标文件名的循环显式忽略 ZIP 条目名

备份循环将元组的首个元素绑定为 `_`，而实际写入循环继续保留条目名。该改动仅消除无效绑定，不改变备份文件名或恢复顺序。

## Risks / Trade-offs

- [旧 XCFramework 或 Cargo 缓存掩盖新 target] → 使用脚本完整重建 XCFramework，并在重建后执行 macOS 与 iOS 构建验证。
- [环境变量在目标之间错误复用] → 以 target 分支把变量附着在单个 Cargo 命令前，且在脚本测试中覆盖所有四个 Apple target。
- [原始字节改写意外改变长度字段顺序] → 新增 local file header 的固定小端字节断言，并保留现有导入导出回归测试。
- [Xcode 只显示部分构建日志] → 同时保存脚本与 Xcode build 输出，按完整诊断文本检查三项警告均已消失。

## Migration Plan

1. 先添加 ZIP 小端字段回归断言，并运行其专项 XCTest；记录现有编译诊断作为警告修复前的基线。
2. 修改构建脚本和两个 Swift 源文件，以最小改动消除诊断。
3. 通过 `build-rust.sh` 重建被忽略的 XCFramework，运行 XcodeGen 生成工程，并分别执行 macOS 与 iOS 构建及相关 XCTest。
4. 检查构建输出不含 macOS deployment target 不匹配、两处 `UnsafeBufferPointer` 和一处未使用变量警告。

无需数据迁移或发布兼容层。若需要回滚，恢复三个源文件与构建脚本，并重新运行脚本生成对应的本地 XCFramework。
