# 连接监控事件驱动验证

## 实现与边界

- 核心遥测修改触发订阅，不消费原有生命周期日志队列。每个订阅先接收当前快照，随后等待状态变化。
- 核心按读取顺序分配快照序号；手动读取和推送使用同一序列，Swift 拒绝迟到旧值。
- 页面取消会释放 FFI 订阅；回调在核心状态锁外投递，Swift 在 MainActor 更新，待消费快照容量为一。
- 页面移除一秒轮询；空态首次加载完成后保持稳定，无变化不发布数据。
- 活动触发一次性速率/空闲期限；空连接及稳定空闲时没有期限。新 I/O 从活动发生时开始速率采样，避免空闲期稀释速率。
- 保留手动刷新、健康检查、稳定连接标识、错误语义、累计计数和原有同步查询。未修改网络协议、认证、凭据、平台入口或持久化。

## TDD 证据

| 范围 | Red | Green |
| --- | --- | --- |
| 核心订阅 | 缺少订阅 API 与快照顺序信息，测试无法编译 | 遥测 29 个测试通过；覆盖所有可展示字段、无效 ID、独立订阅、突发合并、时间边界 |
| FFI 订阅 | 缺少回调接口及取消句柄，测试无法编译 | 遥测 14 个测试通过；回调中再次查询无死锁、重复取消、对象释放及多订阅独立 |
| Swift 订阅 | 缺少订阅注入、观察方法及首次加载标志，测试无法编译 | 连接监控 17 个测试通过；包含真实 Rust→Swift 初始回调及健康检查后的新故障 |
| 旧推送晚于手动刷新到达 | XCTest 实际失败：99 字节回退为 1 字节 | 核心顺序号使旧推送被拒绝；另有慢手动读取被新推送超越的测试 |
| 健康检查后发生故障 | XCTest 实际失败：健康检查返回 Healthy 后覆盖了核心较新的 Failed/Unavailable | 改为读取带顺序号的核心完整快照 |
| 空闲恢复速率 | 可控时钟测试实际失败：空闲 60 秒后首包被算成 1 B/s | 活动重新开启窗口，250ms 后得到 400 B/s，且稳定空闲无周期唤醒 |

## 此前实现验证

- `cargo test --offline`：1063 通过，0 失败，4 个既有 ignored（增加最后一个空闲恢复用例前，包含文档测试）。
- 最终 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`：1063 通过，0 失败，4 个既有 ignored（已包含新增用例，不含文档测试）；lines **96.3122%**、regions **96.2020%**，门禁通过。
- 最终 `telemetry.rs`：lines 99.4003%、regions 99.1379%；`ffi_telemetry.rs`：lines 99.4083%、regions 99.4792%。
- 最终 `build-rust.sh` → `xcodegen` 通过；macOS 连接监控 XCTest **17/17** 通过，包含构建与真实 FFI 回调验证。
- iPadOS 真机目标构建通过；最终 iPad 模拟器连接监控 XCTest **17/17** 通过。
- OpenSpec 提案及两个主规格严格验证通过；非生成文件 `git diff --check` 通过。

自动测试验证了状态投递、排序、取消和空态通知行为。没有连接用户真实 SSH 主机，也没有进行人工 GUI 操作或屏幕采集，因此不把测试结果表述为真实网络环境下的零延迟保证。

## 归档核查（2026-09-24）

| 要求 | 实现与测试证据 | 验收范围 |
| --- | --- | --- |
| 初始快照、所有可展示修改、多订阅与合并 | `telemetry.rs:264`、`:290`；`telemetry/subscription_tests.rs` 的初始窗口、多订阅、全部字段及突发计数用例 | 核心单测与全量 Rust |
| 无变化不发布、空态不轮询 | 订阅比较 records 后返回；`ConnectionMonitorView.swift:103` 只发布变化，`:353` 绑定订阅，无固定读取循环；Swift 重复快照与空态测试 | 核心与双端 Swift |
| 速率归零、五秒空闲、稳定后无期限 | `telemetry.rs:223`、`:564`；可控时钟测试涵盖窗口、4999/5000ms、活动重排及长空闲恢复 | 核心单测 |
| 锁外 FFI 回调、独立取消与释放 | `ffi_telemetry.rs:43`、`:48`、`:55`；观察者回调中再次查询，验证锁外回调；重复取消及释放测试 | FFI 单测与真实 Swift 初始回调 |
| 有界队列、页面取消与迟到值隔离 | `ConnectionMonitorView.swift:68` 容量一 AsyncStream、终止取消与 observationID；取消/重挂载 XCTest | 双端 Swift |
| 手动读取与推送双向乱序、健康检查权威状态 | 核心锁内 revision；Swift `apply` 拒绝旧值，检查后重读核心快照；三项竞态回归 | 核心、FFI 与双端 Swift |
| 卡片稳定标识及结构、保留手动操作 | `ConnectionMonitorView.swift:319` 的稳定 ID、固定布局和数字字体；刷新、健康操作及格式化测试 | 源码核查与 Swift 测试；无人工 GUI 验收 |
| 现有 API、全局 runtime、无新增网络/凭据/持久化副作用 | 核心订阅仅内存与单次期限，FFI 沿用全局 runtime；相关 diff 与接口核查 | 不以真实主机操作作验收前提 |
| 两个 delta 与主规格同步 | `connection-monitoring/spec.md:64`、`ffi-bridge/spec.md:313`；strict 校验 | 已同步，归档前再比对 |
| Rust 全量、工作区与分包/逐文件门禁 | 最新 cargo test 1069 通过、0 失败、4 个既有 ignored；此前工作区 96.31795% / 96.20826%，核心包 95.41788% / 95.75216%；补测后 FFI 包 lines 97.33174%，delete 98.34711%、sessions 99.53380%，batch 91.88406% | batch 仍未达逐文件 95%；最终完整门禁未完成，不能用包级替代逐文件 |
| Apple 生成边界与双端全量 | 此前绑定、双端构建与各 17 项监控测试通过；导航修正后 iPad 全量 579/579，macOS 全量 683/684 | 唯一日志并发用例失败；定向十轮五失败，不以此前绿色全量覆盖本次结果 |
| Linux 交叉编译 | 缺少 `x86_64-linux-gnu-gcc` | 用户明确暂缓验收，不记通过 |
| 归档交付 | 当前目录仍为活动提案 | 剩余门禁通过并确认归档范围后执行 |

补测及关联修复详见仓库路径 `openspec/changes/fix-swift-test-regressions/verification.md`。本地化空参数崩溃、窗口夹具生命周期、停机会话清理及导航断言时序已修正。最新报告为 `build/event-monitor-supplement-{ios-full,macos-full}.xcresult`、`build/event-monitor-supplement-rust-full.log` 和 `build/ffi-supplement-coverage.json`；原日志并发用例复现报告为 `build/event-monitor-logger-race-repro.xcresult`。日志刷新存在并发旧快照覆盖窗口，batch 剩余错误路径需私有执行器补测。用户于 2026-09-24 明确批准四源码与六份记录的修复范围，并在 11:20 UTC 确认审批已修复、解除暂停；11:21 UTC 十文件备份成功，位于 `build/event-monitor-audit-backup/final-blockers-20260924-1121/`。正在按先测后改执行，不降低门禁；归档前仍另行确认具体范围。

## 限制与历史问题

- Linux 按用户 2026-09-24 明确指令暂缓；没有安装交叉编译工具，无新增生产依赖或 Apple 专属核心代码。
- 第一轮覆盖率测试与普通测试并行时，共用 `ffi_fake_server` 固定临时目录发生清理冲突；后续 Rust 验证串行运行。
- UniFFI 生成的 C 头文件沿用生成器尾随空格格式，源码格式检查与生成文件分别处理。
- 没有人工 GUI、屏幕采集或用户真实 SSH 主机验证，不宣称真实网络环境的零延迟保证。

核心与 UI 实现及规格同步已有证据；最终全量门禁已通过。

## 最终门禁验收（2026-09-24 12:08 UTC）

- Rust 全量：**1074 通过、0 失败、4 个既有 ignored**，退出码 0。
- Rust 覆盖率门禁通过：工作区 lines **96.32%**、regions **96.21%**；核心包 lines **95.42%**、regions **95.76%**；FFI 包 lines **97.98%**。十个必需 FFI 文件全部 ≥95%，含 `batch_transfer.rs` **96.49%**。
- macOS 全量：**687 通过、0 失败、0 跳过**，退出码 0。
- iPad 全量：**582 通过、0 失败、0 跳过**，退出码 0。
- 双端日志十轮：各 **50/50 通过、0 失败**，退出码 0。
- Linux 按用户 2026-09-24 指令暂缓验收；没有执行真实 SSH 主机或人工 GUI 验收。

详细修复记录见 `openspec/changes/fix-swift-test-regressions/verification.md`。
