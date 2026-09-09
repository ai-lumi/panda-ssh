## Why

macOS 主窗口启动后顶部栏正常，但失焦或选择主机后整行按钮和页签消失。当前自绘栏伸入系统标题栏，窗口桥接在视图更新时重复设置窗口属性；需通过 Mock 窗口区分属性重写、几何偏移与遮挡，修复可验证的原因。

## What Changes

- 保证 macOS 顶部栏在失焦、重新聚焦、选择主机后持续可见。
- 对窗口 chrome 配置实施幂等保护，正常状态更新不重复重设相同属性。
- 增加真实 AppKit 窗口回归测试，覆盖属性偏离后的恢复与宿主生命周期。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`：补充 macOS 顶部栏跨焦点和主机选择变化的可见性约束。

## Impact

仅修改 macOS 窗口宿主及相关 XCTest；不涉及 Rust、FFI、网络与凭据。iPadOS 行为不变。保留工作区已有防闪烁改动。

## Non-goals

不更改页签、会话、主机选择的业务语义；不重做整体布局；不以强制定时重绘或恢复全树高频刷新掩盖问题。
