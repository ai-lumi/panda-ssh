## 1. 验证与回归测试

- [x] 1.1 运行 `cargo test` 确认 Rust 核心全绿
- [x] 1.2 运行 macOS 端 `PandaSSH-macOSTests` 全量测试（220 项），确认选择模型与批量传输逻辑无回归
- [x] 1.3 运行 iOS 端 `PandaSSH-iOSTests` 全量测试（220 项），确认共享源码在 iPadOS 无回归
- [x] 1.4 手动验证：在 macOS 预览/运行态中框选多个文件，确认蓝色选区矩形与实际选中条目一致

## 2. 修复框选坐标错位

- [x] 2.1 将 `SftpTabView.fileList` 的 `List` 替换为 `ScrollView { LazyVStack(spacing: 0) { ... } }`
- [x] 2.2 用 `.padding(...)` 与 `.frame(minHeight: 22)` 保持原 List 行高与行间距视觉一致
- [x] 2.3 保留 `GeometryReader` 行 frame 上报、`DragGesture` 框选手势、选区矩形 overlay、空目录提示等既有行为

## 3. 工程配置与构建门禁

- [x] 3.1 在 `apple/project.yml` 中显式声明 `PandaSSH-macOS` 与 `PandaSSH-iOS` scheme，并绑定对应测试 target
- [x] 3.2 重新执行 `xcodegen generate`，确认生成工程可通过 `xcodebuild -scheme PandaSSH-macOS test` 直接运行测试
- [x] 3.3 执行 macOS/iOS 双端 `xcodebuild build`，确认无编译错误
