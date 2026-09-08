## 方案
共享布局和视图增加默认开启的 showsCustomSidebarRecovery 参数；iPad 宿主明确传入 false。恢复按钮的可见性和宽度使用同一判断，macOS 调用保持默认。仅调整 UI，不涉及 Rust、FFI 或会话。

## 验证
先新增失败 XCTest，覆盖隐藏、展开、反复切换、窄宽度、零宽度及无效宽度；现有 macOS 恢复按钮测试保持通过。尝试 iOS 构建，真机确认只存在系统恢复按钮。
