# Swift 失败清单与修复验证

## 修复前的失败清单

定向复现：`/tmp/panda-swift-red.log` / `/tmp/panda-swift-red.xcresult`，39 项中 30 通过、9 失败，退出码 65。

| 测试 | 证据与根因 | 处理 |
| --- | --- | --- |
| LocalizationResourceTests.testUnknownDescriptorCodeReturnsGenericError | 空参数构造 `1..<0`，SIGTRAP | 遍历实际存在的相邻索引；补已知零参数和缺参模板测试 |
| MainWindowChromeLifecycleTests.testSwiftUI宿主更新拆卸及无原生按钮窗口 | 旧隐式拖窗断言；宿主运行时类型替换导致崩溃，进一步暴露测试固定等待不足 | 对齐显式拖动契约，保留宿主类型，验证挂载/更新/拆卸 |
| MainWindowChromeLifecycleTests.test切换宿主后旧窗口的异步恢复不得继续执行 | SwiftUI ViewGraph 内存访问错误 | 删除跨类型缓存与 isa 替换，使用公开窗口属性 |
| MainWindowChromeLifecycleTests.test窗口属性偏离后在焦点通知中恢复 | 同上 | 同上 |
| MainWindowChromeLifecycleTests.test解绑后通知不得重新配置窗口 | 同上 | 同上 |
| MainWindowChromeLifecycleTests.test重复挂载与焦点尺寸通知不重写已正确的窗口属性 | 同上 | 同上 |
| TabStripIntrinsicWidthTests.test空间充足时页签栏视图层级元素数量合理 | 之前关闭的窗口在 `_NSWindowTransformAnimation dealloc` 中重复释放 | 夹具设置 `isReleasedWhenClosed = false` |
| TransferPanelViewTests.test失败组仍然可见 | 同上，异步动画导致失败归属落在后续用例 | 夹具显式持有窗口至关闭，禁止关闭时自行释放 |
| TransferPanelViewTests.test空目录组可见 | 同上 | 同上 |

旧全量日志还将 TransferPanelViewTests.test组成员数量正确 记为未结束；该次定向运行通过，后续需全量确认。日志缓冲测试已通过（旧全量约 62 秒），不属于失败，不为本次修复改日志架构。

## TDD 与定位补充

- `/tmp/panda-localization-red.log`：新增已知零参数和缺参模板用例均先崩溃。修复空区间后，已知零参数用例继续失败，揭示格式化分发漏了零参数分支，随后补齐。
- `/tmp/panda-host-types-red.log`：新增不同原生/SwiftUI 宿主类型与同窗替换用例先失败。
- `/tmp/panda-host-types-diagnosis.log`：实际挂载类型为 `NSKVONotifying_*`。仅按父类分别缓存动态子类仍触发 `NSDP_getComputedPropertyValue` 断言，不能保证 KVO 正确。
- `/tmp/panda-host-public-api-red.log`：保留原始宿主类型、关闭背景隐式拖窗的行为断言先失败。随后删除运行时类型替换，改用 `isMovableByWindowBackground`；原有显式拖动、双击、控件隔离测试保留。
- `/tmp/panda-swift-focused-final.log`：55 项中 54 通过，已无崩溃。
- `/tmp/panda-chrome-lifecycle-diagnosis.log`：独立运行通过，实际记录确认异步挂载完成配置；测试固定 50ms 在全量调度下不足，改为有 2 秒超时的状态条件等待，保留挂载、更新及拆卸断言。
- `/tmp/panda-swift-focused-verified.log`：相关 55 项连跑 3 轮，共 **165 通过、0 失败**，退出码 0。

## 本轮验收（2026-09-24）

- 停机 Red：`build/event-monitor-shutdown-red.log` / `.xcresult`，1 项用例失败、5 个断言失败。核心已关闭标签，但 Swift 会话及关闭通知未清理，重复停机仍未补齐。
- 停机修复：保存关闭前标签集合，复用 `syncAndReleaseSessions`；保留拒绝新连接和重复停机不重复释放的行为，不改变 Rust / FFI 契约。
- macOS 定向 Green：`build/event-monitor-shutdown-green.log` / `.xcresult`，连接监控 17 项与工作区状态 7 项共 **24/24 通过**。
- macOS 全量：`build/event-monitor-audit-macos-final.log` / `.xcresult`，**684/684 通过，0 跳过**，退出码 0。
- iPad 首轮全量：`build/event-monitor-audit-ios.log` / `.xcresult`，**577 通过、2 项失败，0 跳过**；日志计为 4 个失败断言。该构建早于停机修复，失败项为停机清理与 `GlobalTransferNavigationTests.test空工作区允许打开并返回主机页`。
- iPad 导航失败：`AppModel.selectHost` 将切页更新放入主队列，测试却立即断言；同测试类已有 `drainMainQueue`，该用例遗漏等待。macOS 的 `showTransfers` 不切页，不能用其通过结果证明 iPad 正确。暂未修改该测试文件。
- 修复后的 iPad 定向复验：`build/event-monitor-audit-ios-focused.log` / `.xcresult`，**26 通过、1 项失败，0 跳过**，退出码 65。连接监控 **17/17**、工作区状态 **7/7** 通过（包含停机及重复停机断言）；唯一失败仍为导航用例。停机修复已双端定向验证，但不能将该结果记作 iPad 全量通过。
- Rust 本轮工作区覆盖率：lines **96.31795%**、regions **96.20826%**；核心独立包覆盖率：lines **95.41788%**、regions **95.75216%**。
- FFI 隔离报告 `build/event-monitor-audit-ffi-coverage.json` 的包级 lines 为 **95.02190%**，但 `batch_transfer.rs` **87.53623%**、`ffi_delete.rs` **92.56198%**、`ffi_sessions.rs` **92.77389%** 未达到 `scripts/verify-rust-coverage.sh` 规定的逐文件 95%。三个产品文件无本次 diff，不能据此豁免门禁；本轮未修改其测试或覆盖率规则。
- FFI 逐行复验：`build/event-monitor-audit-ffi-detail.log` / `.json`，**287 项通过、0 失败**，上述覆盖率可重复。按文件合并后的 `segments` 而非单个实例的零计数确认：批量 SFTP 创建失败（210–216）及扫描失败（251–258）、远端删除入口（146–157）、tracked 会话正常打开与已初始化查询路径均有未执行区域；区域未执行不等于其所在整行未覆盖。
- 假服务测试 `ffi_fake_server.rs:2718`、`:2746`、`:3635` 未预置信任新服务器，仅检查 Failed 或非空错误；批量连接采用 Reject 策略，现有断言不足以证明到达扫描或子系统失败分支。首批补测候选可集中在该测试文件：建立正确前置条件并收紧失败原因断言，补远端删除与 tracked 会话的成功、失败和边界用例；是否达标仍须重跑逐文件门禁确认。该文件尚未获准修改。
- 连接监控提案、两个主规格及本修复提案的 strict 校验通过；停机实现及测试的 `git diff --check` 通过。
- Linux 按用户 2026-09-24 指令暂缓验收；环境缺少 `x86_64-linux-gnu-gcc`，不记为编译通过。没有执行真实 SSH 主机或人工 GUI 验收。

## 获准补测后的进展

2026-09-24 用户批准备份并修改 `AppModelSelectionTests.swift`、`ffi_fake_server.rs` 及两个提案的相关验收记录；不修改产品逻辑、不降低门禁、不提交，归档前另行确认范围。备份位于 `build/event-monitor-audit-backup/supplement-20260924-1035/`。

导航测试只增加已有 `drainMainQueue()` 调用，保留原断言。Red 为首轮全量及定向均在切页前断言失败；Green 为 `build/event-monitor-navigation-green.log` / `.xcresult`，iPad 导航与模型 **16/16 通过、0 跳过**，退出码 0。

### 补测后的实际结果

- `build/event-monitor-supplement-ios-full.log` / `.xcresult`：**579/579 通过，0 跳过**，退出码 0。
- `build/event-monitor-supplement-macos-full.log` / `.xcresult`：**683 通过、1 用例失败、0 跳过**，退出码 65。唯一失败为 `LoggerFileTests.testConcurrentWritesDoNotCrashOrLoseEntries`，两断言均为 99 而非 100；导航、停机、连接监控用例通过。
- `build/event-monitor-logger-race-repro.log` / `.xcresult`：原日志并发用例不改源码执行十轮，**5 通过、5 失败**，失败时为 98 或 99 条。测试已用 DispatchGroup 等待全部同步日志调用返回，问题不能解释为仅等待主队列不足。`Logger.swift:133-155` 在调用线程完成读取、映射和 `@Published` 赋值，无串行化和主线程约束，允许旧快照晚于新快照发布；需要补充主线程发布与核心/呈现一致性断言后最小修复。日志产品及测试文件尚未获准修改。
- FFI 三个批量错误用例先收紧断言，`build/ffi-supplement-red.log` 中 **3 项均实际失败于 UnknownHostKey**；加入 `test_connection(..., true)` 信任回环服务器后，`build/ffi-supplement-green.log` 最终 **3/3 通过**。日志保留早期命令参数错误及一次 Display 文本断言修正，二者不混作产品失败。
- 新增 tracked Shell/SFTP 两项及远端删除三项，分别覆盖代次取消/重开、真实 I/O、文件/目录删除、缺失路径、空/越界目标和无效句柄；`build/ffi-supplement-new-tests.log` **5/5**，完整假服务 `build/ffi-supplement-integration.log` **73/73**。
- `build/ffi-supplement-coverage.log` / `.json`：FFI **292 项通过**，包级 lines **97.33174%**；`ffi_delete.rs` **98.34711%**、`ffi_sessions.rs` **99.53380%**。十个必需文件九个达标，`batch_transfer.rs` **317/345 = 91.88406%**，至少还需覆盖 11 行；不得把命令退出 0 当成逐文件门禁通过。
- batch 剩余缺口包括执行器再次读取主机失败、store 再次读取失败和固定默认选项下的执行结果错误映射。现有公共集成入口不能确定性触达全部路径；未制造共享状态竞态、改变产品或降低门禁。完整代理证据在 `build/ffi-supplement-summary.json`，实际 diff 与报告已由主代理复核。
- 补测后 `cargo test --offline`：`build/event-monitor-supplement-rust-full.log`，**1069 通过、0 失败、4 个既有 ignored**，退出码 0；保留核心测试的 31 条 `unused_mut` 警告，不宣称输出无警告。

## 四文件修复恢复

2026-09-24 用户已批准 `Logger.swift`、`LoggerTests.swift`、`batch_transfer.rs`、`src/tests/batch_transfer_tests.rs` 与六份提案记录的修改。此前备份被审批错误拒绝，未发生源码写入，用户曾明确暂停；11:20 UTC 用户确认审批已修复并解除暂停，11:21 UTC 十文件备份成功，位于 `build/event-monitor-audit-backup/final-blockers-20260924-1121/`。修复严格保留日志及传输业务规则、全部错误分支和门禁，归档前另行确认范围。

日志 Red：`build/event-monitor-logger-main-thread-red.log` / `.xcresult`，5 项中 3 通过、2 失败；后台写入与清空均在 `Thread.isMainThread` 断言失败，非编译错误。并发用例新增 Rust 同步缓存内容和 Swift 顺序/ID 一致性检查；另补清空后的迟到刷新不能恢复旧条目。最小修复将整个 `refreshEntries()` 在后台调用时派发主线程，而非仅派发最终赋值；主线程调用仍同步执行，保留原日志规则。Green：`build/event-monitor-logger-main-thread-green.log` / `.xcresult`，五个用例十轮共 **50/50 通过、0 失败、0 跳过**，退出码 0；结果包统计明确为 50 次运行，不把顶层五个唯一用例误作执行次数。最终双端全量尚待重建后验证。

私有批量执行器及失败转换契约已在上一会话完成补测，最终门禁全部通过。

## 最终门禁验收（2026-09-24 12:08 UTC）

- Rust 全量：`cargo test --offline`，**1074 通过、0 失败、4 个既有 ignored**，退出码 0。
- Rust 覆盖率门禁：`scripts/verify-rust-coverage.sh` 通过。工作区 lines **96.32%**、regions **96.21%**；核心包 lines **95.42%**、regions **95.76%**；FFI 包 lines **97.98%**。十个必需 FFI 文件全部 ≥95%：`batch_transfer.rs` **96.49%**、`ffi_delete.rs` **98.35%**、`ffi_sessions.rs` **99.53%**、`ffi_telemetry.rs` **99.41%**、`ffi_transfers.rs` **96.39%**、`ffi_workspace.rs` **99.73%**、`ffi_store.rs` **96.29%**、`task_aggregation.rs` **96.92%**、`ffi_runtime.rs` **100%**、`lib.rs` **100%**。
- macOS 全量：`build/event-monitor-final-macos.log` / `.xcresult`，**687 通过、0 失败、0 跳过**，退出码 0。
- iPad 全量：`build/event-monitor-final-ios.log` / `.xcresult`，**582 通过、0 失败、0 跳过**，退出码 0。
- iPad 日志十轮：`build/event-monitor-logger-ios-green.log` / `.xcresult`，5 项用例 × 10 轮 = **50/50 通过、0 失败**，退出码 0。
- macOS 日志十轮：`build/event-monitor-logger-main-thread-green.log` / `.xcresult`，5 项用例 × 10 轮 = **50/50 通过、0 失败**，退出码 0。
- Linux 按用户 2026-09-24 指令暂缓验收；环境缺少 `x86_64-linux-gnu-gcc`，不记为编译通过。没有执行真实 SSH 主机或人工 GUI 验收。

全部门禁通过，提案可归档。归档前须用户另行确认具体范围。
