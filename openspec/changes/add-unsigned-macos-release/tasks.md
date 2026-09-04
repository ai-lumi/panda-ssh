## 1. 构建契约测试

- [x] 1.1 新增发布脚本契约测试，先覆盖正常流程（双 macOS 架构与发布步骤）、意外配置（重新启用签名或缺少测试门槛）和边界条件（仅 iOS arm64 slice 不被误改）。

## 2. Universal macOS 构建

- [x] 2.1 扩展 Rust XCFramework 构建脚本，加入 Intel macOS slice，同时保持 iOS device/simulator 的既有目标。
- [x] 2.2 配置 macOS Release Archive 为无 Developer ID 的 Universal App，不修改 iPadOS 配置。

## 3. 自动发布工件

- [x] 3.1 新增 GitHub Actions：版本标签触发、Rust 测试、构建、架构验证、ZIP/DMG 打包和 GitHub Release 上传，并包含安全的无 Developer ID 安装说明。

## 4. 验证

- [ ] 4.1 运行发布脚本契约测试、OpenSpec 严格校验、Rust 测试与覆盖率门禁。
- [x] 4.2 在本机完成 Release Archive，并检查 App 可执行文件与 XCFramework 包含 `arm64` 和 `x86_64`；记录无法完成的环境限制。
