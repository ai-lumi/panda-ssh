# 当前版本提案归档复核

> 复核日期：2026-09-11｜源码基线：`b138c38`｜范围：18 个当前版本未归档提案。
> 下一版本尚未实施，其 9 个提案按[下一版本范围](../next-release.md)排除。

## 结论

当前版本尚不满足整体归档条件。18 项中，11 项已有主体实现，4 项仍需完成实现或集成，3 项历史 UI 方案需记录被替代的范围并收尾。不能把任务勾选、提案格式校验通过或编译通过等同于验收完成。

本轮重新运行了 Rust 测试与覆盖率、macOS XCTest、双端测试目标编译和 OpenSpec 校验。只新增本报告；未修改生产代码、测试、主规格或当前版本提案，未归档、提交或发布。

## 本轮验证结果

| 检查 | 实际结果 | 结论与边界 |
| --- | --- | --- |
| 当前版本 18 项 `openspec validate <change> --strict` | 18/18 通过 | 仅证明工件格式有效；`fix-tab-strip-rightmost-truncation` 仍缺 design 工件 |
| `openspec validate --specs --strict --json` | 25/26 通过 | `snippets` 的“当前实现状态”被解析为 Requirement，缺 SHALL/MUST 与 Scenario |
| `cargo test --workspace --offline` | 489 项通过（含 1 项文档测试），0 失败，4 项真实服务器测试忽略 | 首轮沙箱拒绝回环监听；获准重跑本地 fake SSH 后通过，没有连接真实服务器 |
| `cargo llvm-cov --workspace --tests --offline --fail-under-lines 95 --fail-under-regions 95` | 退出码 1；lines 93.20%，regions 92.70% | 当前实测结果，两项均未达到 95% |
| macOS `build-for-testing` | 通过 | 使用当前 Swift 源码与现有 XCFramework、生成绑定和工程；旧记录中的测试目标编译错误已不能作为当前结论 |
| macOS `test-without-building` | 444 项：409 通过、35 失败；70 处失败断言，退出码 65 | 使用临时目录中的独立测试实例，配置路径隔离；全量门禁未通过 |
| iPadOS arm64 模拟器 `build-for-testing` | 通过 | 使用 `ARCHS=arm64`；未运行 iPadOS XCTest 或真机验收 |
| `cargo check -p panda-core --target x86_64-unknown-linux-gnu --offline` | 未完成；缺 `x86_64-linux-gnu-gcc` | 属于交叉编译环境缺口，不能证明平台兼容或不兼容 |
| 旧 UI 退役静态契约 | 3 项通过 | 旧组件、回退开关和旧溢出偏好未重新进入生产装配 |
| 无签名 macOS 发布静态契约 | 通过 | 不等同于本轮重新生成 Universal Release、ZIP/DMG 或运行远端发布工作流 |

本轮没有重跑 `build-rust.sh → xcodegen`，因此双端测试编译不替代完整 FFI 产物重建门禁。未重新测量 Swift 全应用覆盖率，不以 Rust 覆盖率代替；历史记录中的 Swift 40.42% 或 61.76% 也不是当前测量结果。

### 当前 Swift 失败分布

| 测试类 | 失败用例数 | 复核到的现象及后续判断点 |
| --- | ---: | --- |
| `AppModelSelectionTests` | 8 | 实现通过主队列异步更新选择，测试立即读取；先明确选择提交时序，再补正确等待与快速操作回归 |
| `GlobalTransferNavigationTests` | 1 | 同样在主机选择尚未提交时断言；需要与选择契约一同处理 |
| `FilePaneNavigatorTests` | 2 | 目录下载分组缺失、混合文件和目录数量不符；需核对扫描 fixture、Rust 聚合与任务源之间的完整映射 |
| `LoggerBufferTests` | 4 | 日志顺序与条数不符；Rust 全局 logger 与旧 Swift 实例级隔离假设不同 |
| `LoggerFileTests` | 7 | 临时目录、轮转和重新初始化断言失败；Swift 初始化参数保留但不再驱动 Rust 存储，需修复注入契约或重建对应层级的测试 |
| `TransferStoreTests` | 9 | 分组丢失、组取消/重试无效、速度始终为零；区分 Mock 未适配与真实路径缺陷后修复 |
| `WorkspaceStoreTests` | 4 | 标题序号空格及跨主机名称映射不符；需要统一 Rust 输出、主机名注入和规格预期 |

以上失败不全部等同于生产故障；也不能统称“旧测试问题”后删除断言。应逐项确定当前正确契约，用正常、失败和边界用例验证修复。

## 逐提案结论

下表的“收尾”均以公共测试、覆盖率和规格门禁通过为前提；不是立即归档许可。任务计数按当前清单原样统计，`[~]` 单独列出。

### 已有主体实现：11 项

| 提案 | 勾选记录 | 本轮核对及剩余条件 |
| --- | --- | --- |
| [align-apple-build-targets-and-config-warnings](../changes/align-apple-build-targets-and-config-warnings/tasks.md) | 10/10 | 部署目标设置保留；旧 Swift 归档工具已被 Rust 迁移替代。无需 spec delta，收尾时更新当前验证依据；按要求完成完整产物重建与告警复核 |
| [fix-sftp-directory-upload-path-duplication](../changes/fix-sftp-directory-upload-path-duplication/tasks.md) | 8/8 | 修复和三个目录上传回归用例存在，本轮专项用例通过；主规格尚缺中文目录上传场景，需语义合并 delta |
| [add-unsigned-macos-release](../changes/add-unsigned-macos-release/tasks.md) | 5/6 | 脚本、双架构配置和工作流存在，静态契约通过；补覆盖率门禁，复核 Universal Release 工件证据并同步规格；`unsigned-macos-release` 主规格尚不存在 |
| [fix-sftp-batch-upload-blocking](../changes/fix-sftp-batch-upload-blocking/tasks.md) | 18/18 | 扫描、冲突等待及目录上传路由已改；“超时后失败”与实现超时跳过不一致，取消唤醒测试不能替代超时测试；非阻塞实现采用 `block_in_place`，设计需准确反映实际线程模型。补验收后同步两个 delta |
| [fix-tab-strip-rightmost-truncation](../changes/fix-tab-strip-rightmost-truncation/tasks.md) | 0/13 | 自适应 anchor、内容宽度与对应测试已存在，本轮 viewport 测试通过；补 design、更新真实任务状态，统一主规格已有场景与 delta 的新 Requirement，补实际窗口几何验收 |
| [fix-terminal-exit-status](../changes/fix-terminal-exit-status/tasks.md) | 7/8 | Rust 远端退出测试及 Swift 退出处理存在；delta 仍要求按主机共享连接和延迟断开，与当前所有者独占连接冲突。保留退出输出/状态语义，按当前所有权合并，不恢复共享连接 |
| [fix-window-top-flicker-on-transfer](../changes/fix-window-top-flicker-on-transfer/tasks.md) | 13/18 | chrome 去重、非订阅传输注入、分栏幂等路径存在；仍缺真实传输期间顶部稳定、空闲 CPU、侧栏/窗口变化、多会话连续性验收，两个 delta 未同步 |
| [fix-workspace-tab-close-identity](../changes/fix-workspace-tab-close-identity/tasks.md) | 3/5 | UUID 适配与先移除页签再释放会话存在，关闭回归通过；当前 WorkspaceStore 其余四项标题测试仍失败；无 delta，等待公共门禁与真实警告框/会话验收 |
| [refactor-sftp-global-transfers](../changes/refactor-sftp-global-transfers/tasks.md) | 13/16 | 两个能力的五个 Requirement 已与主规格同步；缺选择/分组相关回归修复、Swift 覆盖率及宽窄布局、窗口重复激活、关页后任务继续的验收 |
| [terminal-mouse-interaction](../changes/terminal-mouse-interaction/tasks.md) | 18/31 | 双端终端子类、菜单与 PRIMARY selection 已接入，本轮 macOS 相关测试通过；更新任务证据，补 iPadOS 测试、Swift 覆盖率、触摸/外接鼠标/Universal Control 验收，再同步 workspace delta |
| [use-alert-for-connection-close](../changes/use-alert-for-connection-close/tasks.md) | 4/10 | 双端单项/批量 `.alert` 已接入，本轮关闭相关回归通过；补双端系统警告框人工验收、覆盖率记录并同步更严格的 alert 与批量确认规格 |

### 部分实施：4 项

| 提案 | 勾选记录 | 不能直接归档的原因 |
| --- | --- | --- |
| [migrate-business-logic-to-rust](../changes/migrate-business-logic-to-rust/tasks.md) | 199/207 | `TerminalSessionStore`、`ConnectionGate`、`AppModel.pendingTofu` 及选择逻辑仍在 Swift；工作区关闭确认也保留 Swift 决策。FFI 中仍存在业务聚合实现。需完成已承诺的分层收口、修复受影响测试、补覆盖率与验证日志，再合并 10 个能力的 delta |
| [rust-sftp-task-aggregation](../changes/rust-sftp-task-aggregation/tasks.md) | 31/33 | 分组生成已接入 Rust，但 Swift `taskGroups`、`cancelGroup`、`retryGroup` 仍自行实现规则；core 组级计划未通过对应 FFI 接入。tasks 对“保留现状”的描述与 proposal/design 的收口目标不一致；需补齐边界并通过真实/Mock 契约回归 |
| [define-ssh-content-page-lifecycle](../changes/define-ssh-content-page-lifecycle/tasks.md) | 2/8 | 画布及呈现策略已接入，进度超过勾选；`requestsTerminalResize` 目前只被策略测试读取，生产 resize 仍靠现有 shell 分支。需补真实装配、尺寸变化、可见性和会话连续性测试，明确最终契约，再同步规格 |
| [improve-sftp-task-interactions](../changes/improve-sftp-task-interactions/tasks.md) | 2/28 | core 删除任务/摘要、部分修订通知有实现；完整删除任务 FFI、远程适配、任务页与删除进度、右键选择、退出保护尚未接通。旧聚合桥接仍将 Delete 映射为 Upload；新版类型化契约必须正确处理此方向。须完成任务 2–7 的剩余实现及最终验收 |

### 历史 UI 方案：3 项

| 提案 | 勾选记录 | 正确收尾方式 |
| --- | --- | --- |
| [native-swiftui-chrome](../changes/native-swiftui-chrome/tasks.md) | 28 项 `[x]`，另有 2 项 `[~]` | 原内容区页签栏、旧溢出模式和纯 SwiftUI 装配已被统一 chrome 替代；记录采纳/替代范围，不能重新合并旧要求，也不能把两个 `[~]` 当作通过 |
| [refactor-macos-titlebar-tab-strip](../changes/refactor-macos-titlebar-tab-strip/tasks.md) | 0/13 | 已归档的统一 chrome 提案明确其“不再是实施依据”；viewport 能力已经复用，独立标题栏及旧 UI 回退方案已被替代。按替代关系关闭，不继续实现被禁止的回退路径 |
| [swiftui-workspace-visual-refresh](../changes/swiftui-workspace-visual-refresh/tasks.md) | 26/29 | 保留已采纳的响应式、空态、状态表达和触控要求；principal 工具栏、传输 inspector/sheet 等旧方案与当前规格冲突。先拆清有效与替代项，未完成的无障碍/视觉验收仍需落实，不能整份旧 delta 覆盖主规格 |

替代依据：[统一 chrome 重设计](../changes/archive/2026-09-09-redesign-unified-workspace-chrome/proposal.md)和[旧 UI 退役](../changes/archive/2026-09-09-remove-legacy-workspace-ui/proposal.md)。历史方案收尾时应留下替代原因和承接关系；不是伪造原方案全部完成。

## 必须先解决的公共问题

1. **规格基线有效性。** [snippets/spec.md](../specs/snippets/spec.md) 第 44 行的状态说明应作为说明性章节处理，不能伪装成行为 Requirement。[config.yaml](../config.yaml) 第 8 行仍宣称密钥只进系统钥匙串，和当前凭据文件基线冲突，应同步纠正上下文。
2. **实现与任务记录一致。** 批量冲突超时在 [batch_transfer.rs](../../crates/panda-ffi/src/batch_transfer.rs) 第 373–379 行进入 Skip；[对应测试](../../crates/panda-ffi/tests/ffi_fake_server.rs) 第 3696 行验证取消唤醒。需要先确定正确的产品语义，再补可控制时钟的超时测试，不能沿用“超时失败已验证”的勾选。
3. **完成当前版本的实现范围。** 三个较大的实现缺口是业务下沉、SFTP 聚合、SFTP 任务交互，彼此涉及同一批状态与 FFI。先统一任务类型、聚合、生命周期契约，再补调用链，避免分别实现重复规则。SSH 内容页另补装配和生命周期验证。
4. **通过测试和覆盖率门禁。** 修复上述 35 个 Swift 失败用例对应的契约问题。本轮 `panda-ffi/src/lib.rs` lines 82.91%、regions 82.27%，是 Rust 覆盖率缺口的主要来源；应结合未验证的 FFI 行为补正常、错误和边界测试，不以排除文件或降低门槛达标。
5. **保护当前有效规格。** 多项 delta 同时修改 workspace、transfers；先处理旧 UI 替代关系和独立连接语义，再按实际行为做语义合并。保留已归档变更中的新场景，避免整段旧 Requirement 覆盖新规则。
6. **补齐剩余运行与人工验收。** 完成完整 Apple 产物重建链、iPadOS XCTest、Swift 覆盖率、可用 Linux 环境检查；按提案验证真机鼠标/触摸、VoiceOver、窗口布局与传输/会话连续性。编译或纯策略测试不能替代这些结论。

## 建议收尾顺序与退出条件

| 顺序 | 工作 | 完成标准 |
| --- | --- | --- |
| 1 | 修正当前规格基线、确认三个历史 UI 方案的替代范围 | 主规格严格校验通过，后续合并不会恢复退役 UI 或共享连接 |
| 2 | 先确定失败用例的正确契约并修复，再完成当前版本四项部分实施工作 | 提案承诺与 core → FFI → Swift 调用链一致，正常/失败/边界回归通过 |
| 3 | 完成全量门禁与双端人工验收 | Rust/Swift 测试通过，lines 与 regions 满足约定，剩余构建/平台检查有有效通过证据 |
| 4 | 更新任务与验证记录，合并有效 delta，逐项归档当前版本 18 项 | 每项有完成或被替代的准确依据，主规格与最终行为一致，复跑 OpenSpec 校验通过 |
| 5 | 开始下一版本 | 活动变更仅剩下一版本清单中的 9 项，且当前版本没有隐藏的未完成任务 |

历史 UI 被替代与原方案实施完成应分别记录。若后续需要调整当前版本未完成范围，应另作明确范围决策；本报告没有将任何当前版本任务转移到下一版本。

## 验证证据位置

日志与测试结果存于 `/private/tmp/panda-current-review-20260911-ztw7_69q/`：

- `cargo-test.log`：首轮沙箱回环监听失败，仅作环境诊断。
- `cargo-test-loopback.log`：获准后的完整 Rust 测试通过记录。
- `rust-coverage.log`：当前 Rust 覆盖率表及门禁退出结果。
- `macos-build-for-testing-approved.log`、`ios-build-for-testing-arm64.log`：双端测试目标编译通过记录。
- `macos-tests.log`、`macos-tests.xcresult`：444 项 macOS XCTest 结果。
- `linux-check.log`：Linux 交叉 C 编译器缺失记录。

XCTest 使用独立构建实例及临时 `test-home`；运行前已通过 Foundation 实际读取验证 `homeDirectoryForCurrentUser` 指向该临时目录。未读取用户现用配置，未操作现用 App 或连接真实 SSH 主机。临时日志可能被系统清理，关键结果已摘录到本报告。
