## 1. 标题栏几何可行性验证

- [ ] 1.1 先编写 macOS AppKit 布局探针/XCTest：覆盖侧栏可见的正常窗口、侧栏隐藏或系统恢复按钮存在的意外状态、最小宽度与全屏边界；断言候选标题栏矩形不覆盖红绿灯、系统侧栏恢复按钮或右侧窗口交互区。
- [ ] 1.2 实现仅用于验证的标题栏宿主几何计算与 attach/detach 探针，不改变默认页签栏装配；在目标 macOS 版本实测并记录通过/失败标准。若任一场景无法提供合规矩形，停止后续默认路径接入并修订设计。

## 2. 独立页签 viewport 与输入策略

- [ ] 2.1 先为纯值 `TabStripViewportState` 编写失败测试：覆盖常规溢出、非有限尺寸/零宽度等意外输入、首尾边界与超宽活动页签；验证偏移夹取、按钮状态和最小必要显露。
- [ ] 2.2 实现独立的 viewport 状态与页签 frame 输入，统一提供按钮导航、活动页签显露和边界夹取，且不修改现有 `TabBarScrollMetrics` 或旧页签栏代码。
- [ ] 2.3 先编写失败测试：覆盖传统鼠标单刻度的正常页签步距、混合/缺失 delta 的意外事件、精确设备连续与惯性滚动的边界；验证滚动不切换活动页签。
- [ ] 2.4 实现输入归一化：离散鼠标按受限页签步距移动，精确设备保持连续位移，所有输入复用 viewport 的边界夹取路径。

## 3. AppKit 标题栏宿主与双路径装配

- [ ] 3.1 先编写 macOS XCTest：覆盖标题栏路径可用时的正常装配、宿主失效/显式禁用时的内容区回退、反复切换与窗口关闭时无重复 observer 的边界；验证切换不改变页签顺序、活动页签、连接状态或关闭确认语义。
- [ ] 3.2 实现 `MacOSTitlebarTabStripHost` 与独立 `TitlebarTabStrip` UI 组件；仅在第 1 组几何验收通过后将其装配到标题栏，禁止采用 principal toolbar item。
- [ ] 3.3 实现 macOS 页签栏装配策略：默认请求标题栏路径，宿主不可用、验证失败或明确禁用时回退现有 `WorkspaceTabBar` 内容区路径；保留旧文件、旧组件与旧装配代码，禁止删除或重命名。

## 4. 端到端回归与验收

- [ ] 4.1 先补真实工作区 UI 回归测试：覆盖多终端/SFTP 页签的标题栏正常滚动、窄窗口/侧栏切换等意外布局变化、零页签与大量页签边界；验证不重复绘制页签栏且系统侧栏恢复按钮可用。
- [ ] 4.2 运行新增及受影响的 macOS XCTest、macOS 构建，并在目标 macOS 版本人工验证标题栏几何、拖拽区、全屏、滚轮设备差异与内容区回退路径。
- [ ] 4.3 运行 iPadOS 构建与相关 XCTest，确认 iPadOS 页签栏、侧栏入口和会话生命周期未变。
- [ ] 4.4 运行 `cargo test`、`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`、Swift 受影响 target 测试及 `openspec validate refactor-macos-titlebar-tab-strip --strict`；确认 lines 与 regions 均不低于 95%。
