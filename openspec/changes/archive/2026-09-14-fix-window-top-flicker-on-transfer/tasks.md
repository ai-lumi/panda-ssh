# Tasks: fix-window-top-flicker-on-transfer

## 1. chrome 度量相等性去重（消灭自激渲染环）

- [x] 1.1 新增 `MacosWorkspaceChromeMetricsTests`（XCTest，先红后绿）：对 `objectWillChange` 发布次数计数断言——正常流程（`updateSidebarWidth(300)` 首次发布一次、同值重复调用不再发布、变化后再次发布）；意外操作（NaN/0/负数输入不发布且值不变）；边界条件（无 zoomButton 的窗口走 fallback 路径、同 fallback 值不重复发布、极小窗口宽度夹逼）
- [x] 1.2 `MainWindowChrome.swift` 中 `MacosWorkspaceChromeMetrics.update(window:)` 与 `updateSidebarWidth(_:)` 赋值前加相等性守卫，值不变不赋值；跑 1.1 测试转绿
- [ ] 1.3 手动验证：窗口静止时 Time Profiler 无自发的 `configure`/`metrics.update` 循环调用，空闲 CPU 占用下降；窗口 resize、全屏进出、红绿灯交互行为不变

## 2. TransferStore 注入改造（断开 5Hz 观察链）

- [x] 2.1 新增 `\.transferStore` EnvironmentKey 测试（XCTest）：正常流程（环境值注入后非订阅读取可取得同一实例引用）；意外操作（未注入时使用默认空实现不崩溃）；边界条件（多次注入同一实例返回一致引用）。纯逻辑部分（key 默认值语义）可测；订阅行为不可测处明示以编译期约束兜底
- [x] 2.2 `TransferStore.swift` 新增 `TransferStoreEnvironmentKey`（存引用不订阅）与便捷注入方法；跑 2.1 测试转绿
- [x] 2.3 `PandaSSHApp.swift`：`@StateObject transfers` 改为 init 中创建的 `let` 常量，注入方式改为 `.environment(\.transferStore, transfers)`；独立传输窗口 `TransferPageView(store: transfers)` 直接引用不变
- [x] 2.4 `WorkspaceView.swift`：移除 `@EnvironmentObject transfers`，改读 `@Environment(\.transferStore)`；更新 307 行 `TransferPageView(store:)` 与 398 行 `SftpTabView(tab:host:transfers:)` 两处传参取引用。`SftpTabView`/`TransferPageView` 签名不变——`SftpTabView` 的 `@StateObject session` 初始化链依赖 init 参数注入 transfers，不得改为自读环境值（init 内环境值不可访问，实测 crash）
- [x] 2.5 `SidebarView.swift`：移除 `@EnvironmentObject transfers`；传输入口角标隔离为私有小子视图（读环境值取引用 + `@ObservedObject` 订阅，仅渲染 `activeCount`），侧栏树其余部分不再观察传输状态
- [x] 2.6 更新全部 Preview 注入点（`HostListView` 5 处、`SidebarView` 1 处、`SftpTabView` 预览、`WorkspaceView` 预览等约 8 处）：`.environmentObject(TransferStore())` 改为 `.environment(\.transferStore, ...)`；全项目 grep 确认无残留 `environmentObject(.*TransferStore`
- [x] 2.7 既有 Swift 测试套件全量回归通过；显式确认 `ViewCoverageTests`（含 `SftpTabView(tab:host:transfers:)` 构造用例）、`AppModelSelectionTests`（含 `page?.store === store` 烟雾断言）、`FilePaneNavigatorTests`（直接构造 `SftpSessionStore(host:transfers:)`）因视图签名不变而零修改通过

## 3. 分栏 setPosition 幂等化（可选，防御性加固）

- [x] 3.1 新增分栏宽度判定纯函数测试（XCTest，先红）：正常流程（宽度变化超过阈值返回需要设置）；意外操作（nil 初始状态首次必须设置）；边界条件（差值恰为 0.5pt 不设置、超过 0.5pt 设置、夹逼后往返值不抖动）
- [x] 3.2 `MacosUnifiedSplitHost.Controller.apply` 记录上次应用宽度，按 3.1 判定函数决定是否调用 `splitView.setPosition`；跑 3.1 测试转绿
- [ ] 3.3 手动验证：侧栏拖动、显示/隐藏、窗口 resize 时分栏位置正确跟随且无抖动

## 4. 端到端验证与收尾

- [x] 4.1 双端构建通过：`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build` 与 `-scheme PandaSSH-iOS build`（共享源码改动双端生效；前置 `build-rust.sh` → `xcodegen` 如有工程结构变更）
- [ ] 4.2 手动验证清单全过：上传大文件触发 5Hz tick，主窗口顶部（页签栏/标题栏区域）无闪烁；传输页与「传输任务」独立窗口（另一 scene，`let` 常量直引）进度、速度、剩余时间平滑更新；侧栏角标准确反映活动任务数；SFTP 面板传输完成后自动刷新正常；终端标签页无重绘干扰
- [ ] 4.3 几何与会话回归（在 5Hz tick 期间验证）：增删 SFTP 标签 → 页签栏正常滚动到活动页签；侧栏显隐切换 → chrome 宽度重分配无异常；多 SFTP 标签切换 → 各自文件列表保持独立会话（`@StateObject session` 不被销毁）
- [x] 4.4 覆盖率门禁：新增/改动 Swift 代码 `lines >= 95%` 且 `regions >= 95%`
- [ ] 4.5 归档变更：`openspec archive fix-window-top-flicker-on-transfer`，将 `transfers`/`workspace` delta 合并回主 specs
