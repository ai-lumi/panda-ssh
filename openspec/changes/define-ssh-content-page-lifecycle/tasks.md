## 1. 呈现策略与测试契约

- [x] 1.1 先为纯值 SSH 内容页呈现策略编写失败 XCTest：覆盖 connecting/shell/failed 正常流程、无效尺寸或未知状态意外输入、零尺寸与极宽/极窄边界；验证画布填满、overlay 对齐和只有 shell 请求终端 resize。
- [x] 1.2 实现无条件编译的 `TerminalContentPresentation`，将阶段、可用矩形与终端尺寸所有权收敛为纯值契约。

## 2. 内容画布装配

- [ ] 2.1 先编写 `TerminalTabView` 装配测试：覆盖连接中居中状态、已连接终端独占、失败后重试/关闭；验证不创建第二条 chrome，且不改变现有 `TerminalSessionStore` 尝试代次。
- [ ] 2.2 实现单一全尺寸终端画布与 connecting/failed overlay；保留现有凭据和主机密钥门控、重试、关闭以及 SwiftTerm 会话对象。
- [ ] 2.3 先编写 macOS/iPadOS 尺寸与可见性回归测试：覆盖窗口缩放、全屏、侧栏隐藏/恢复、标签切换的正常流程；连接中/失败态尺寸边界；已连接终端 resize 和会话连续性。
- [ ] 2.4 接入尺寸策略，确保只有已连接 shell 依据既有路径更新 PTY，其他阶段仅重排内容画布。

## 3. 验收

- [ ] 3.1 在 macOS 和 iPadOS 手工验证连接中、已连接、认证/传输失败、远端 shell 结束、窗口缩放和侧栏显隐；确认页面没有第二条 chrome 或错误锚点。
- [ ] 3.2 运行受影响 Swift tests、macOS/iPadOS 构建、`cargo test`、`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 与 `openspec validate define-ssh-content-page-lifecycle --strict`。

## 验证记录

- 2026-09-07：补充真实尺寸归一化和面板宽度测试，先观察缺失属性的编译失败，再实现尺寸策略。画布现从 GeometryReader 接收真实尺寸；状态面板在小窗口中允许滚动，已连接分支继续保留 SwiftTerm。
- `TerminalContentPresentationTests`、`TerminalResizeDebounceTests`、`TerminalSessionTests` 定向 macOS 测试通过；iPadOS arm64 模拟器构建通过；OpenSpec 严格检查通过。
- 上述策略单测不能替代实际 hosting 布局、键盘和侧栏显隐的双端集成验证；2.1、2.3 和人工验收继续保持未完成。此前 1.1 的勾选不能作为历史 red 阶段已执行的证据，尺寸策略的 red-green 本轮才实际补齐。
