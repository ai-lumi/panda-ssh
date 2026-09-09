## Why

当前 Rust 静态库会按本机 SDK 的较新 macOS 版本构建，而 Swift App 保持 macOS 14.0 的最低部署目标，导致 Xcode 链接时产生版本不匹配警告。同时，配置归档工具存在两处悬垂缓冲区指针警告，配置导入器存在一处未使用变量警告，应在不改变配置归档或导入行为的前提下消除这些质量问题。

## What Changes

- 让 Apple Rust 构建脚本为 macOS 和 iOS 目标显式设置与 Xcode 工程一致的最低部署版本，避免静态库在链接时使用更高的系统版本标记。
- 将 ZIP 多字节字段的字节追加实现改为受闭包生命周期约束的原始字节访问，消除 `UnsafeBufferPointer` 悬垂指针警告并保持小端编码。
- 清理配置导入备份循环中未使用的 ZIP 条目名称绑定。
- 增加 ZIP 多字节字段小端编码的回归测试，并在构建验证中检查 macOS 与 iPadOS 产物不再出现上述警告。

## Capabilities

### New Capabilities

无。此变更不引入新的用户可见能力。

### Modified Capabilities

无。此变更不改变既有配置归档、配置导入或跨平台应用的行为需求。

该变更仅调整构建参数和实现细节，因此在 `.openspec.yaml` 中显式声明 `skip_specs: true`。

## Impact

- `apple/Scripts/build-rust.sh`：为 Cargo 的 Apple target 构建注入 macOS 14.0 与 iOS 17.0 的部署目标。
- `apple/PandaSSH/Config/ConfigArchiveUtility.swift`：消除临时字节缓冲区的生命周期警告，保持 ZIP 字段的小端字节序。
- `apple/PandaSSH/Config/ConfigImporter.swift`：移除未使用的元组元素绑定。
- `apple/PandaSSHTests/ConfigExportImportTests.swift`：补充归档字节编码回归覆盖。
- `.github/workflows/macos-release.yml`：沿用脚本中的目标设置，无需单独改变发布契约。
- macOS 保持最低版本 14.0，iPadOS 保持最低版本 17.0；两端用户可见行为、配置格式和公开接口均不变。

## Non-goals

- 不提升 macOS 或 iPadOS 的最低部署版本。
- 不修改 ZIP 格式、配置导入导出语义或现有 `.pandassh` 文件兼容性。
- 不引入新的第三方依赖、FFI 接口或 UI 功能。
