## 任务
- [x] 用户评审批准 iPad 单行布局并要求隔离 macOS。
- [x] 先增加失败测试：编译因缺少 navigationTabStripWidth 而失败。
- [x] 实现 iPad 导航栏页签与宽度策略。
- [x] 验证并记录环境限制。
- [x] 合并规格并归档。

## 验证记录
- iPad 宿主 3 项 XCTest 通过；既有共享布局 6 项 XCTest 通过。
- iOS SDK 语法解析通过，非完整类型检查或应用构建。
- 对比备份确认 WorkspaceView 的修改只在 os(iOS) 的 unifiedIOSBody 内；macOS 分支、共享页签组件和旧布局未修改。
- cargo test --offline 仍在 fake_server 遇到沙箱端口权限错误（70 项失败），未修改 Rust。
- 未重复尝试完整应用构建：前次构建所缺依赖及网络限制未解除。未执行覆盖率门禁、未提交。
- 待真机验收：侧栏显隐、横竖屏和分屏时只有一行导航页签，系统入口可用、多页签滚动正常、空态与关闭确认正常。
