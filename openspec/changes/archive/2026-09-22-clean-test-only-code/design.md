## Context

见 proposal.md。当前测试直接依赖部分生产便利入口；其中一些是重复的状态别名，一些是仅用于构造事件的测试钩子。现行规格已要求批量下载、SFTP 删除、重连和排序，因此不能删除这些能力本身。

## Goals / Non-Goals

**Goals:**

- 删除无生产调用点的包装、局部工具和仅验证该包装的测试。
- 以现有通用入口（例如 `reportConnectionStatus`、`reconnectSession`）替换测试对旧别名的依赖。
- 将事件构造留在 XCTest，不向生产终端视图暴露测试 API。

**Non-Goals:**

- 不移除或降级任何已有 OpenSpec 能力。
- 不更改生成 FFI、SwiftTerm、真实网络或平台服务。

## Decisions

### 按能力而非名称判断删除边界

当测试只验证废弃包装时，删除包装和该测试；当测试验证仍受规格保护的行为时，测试改调仍在使用的正式入口。

备选方案是保留所有测试入口；不采用，因为生产 API 会持续承载测试耦合。

### 测试事件直接调用生产回调

`PandaTerminalView` 的鼠标测试在 XCTest 中构造 `NSEvent` 后直接调用公开的 AppKit 回调，移除 `simulate*` 方法。

理由：真实回调是稳定平台接口，测试钩子不是产品接口。

## Risks / Trade-offs

- [误删仍由 UI 隐式使用的代码] → 删除前重新检索全部生产源，并对照规格；框架回调不删。
- [测试因改用正式入口而掩盖语义] → 保留原有正常、异常和边界断言，只替换入口。
- [SwiftTerm 插件阻塞 XCTest] → 先完成静态和 Rust 验证；插件获准后复跑 macOS/iPadOS XCTest。
