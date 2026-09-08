## 任务
- [x] 1. 方案评审：用户已批准保留系统入口的修复方案。
- [x] 2. 先增加布局回归测试并确认因缺少新参数而编译失败。
- [x] 3. 修改共享布局、视图及 iPad 宿主参数。
- [x] 4. 直接编译运行同一组 XCTest：6 项全部通过；尝试完整构建与 Rust 测试，环境限制见下文。
- [x] 5. 合并规格并归档。

## 验证限制
- iOS 构建未完成：临时构建目录缺少 SwiftTerm / swift-argument-parser 缓存，GitHub DNS 不可用，停止于依赖解析。
- cargo test --offline：panda-core 121 项单元测试通过；fake_server 集成测试绑定本地端口时被沙箱拒绝（Operation not permitted），70 项失败。
- 未完成 iPad 真机视觉验收和完整应用 XCTest；未执行覆盖率门禁，不声称达到 95%，未提交代码。
