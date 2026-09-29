## Verification: fix-macos-tab-drag-and-titlebar-zoom

### 自动化测试证据

#### WorkspaceChromeEventBridgeTests (12 tests, 0 failures)

| 用例 | 类别 | 结果 |
|------|------|------|
| testBlankDragViewOwnsMouseDownInsteadOfPassingItToWindow | 正常 | PASS |
| testDoubleClickOnBlankAreaZoomsWindow | 正常 | PASS |
| testSingleClickDoesNotZoom | 正常 | PASS |
| testTabViewsDoNotInheritWindowDrag | 意外 | PASS |
| testCloseButtonDoesNotInheritWindowDrag | 意外 | PASS |
| testSidebarControlsDoNotInheritWindowDrag | 意外 | PASS |
| testDoubleClickOnNonDragViewDoesNotZoom | 意外 | PASS |
| testSingleClickOnBlankAreaStartsExplicitWindowDrag | 正常 | PASS |
| testZeroWidthDragRegionDoesNotPassMouseDownToWindow | 边界 | PASS |
| testDragViewOnBorderlessWindow | 边界 | PASS |
| testDragViewOnFullScreenWindow | 边界 | PASS |

#### WorkspaceTabDragTransactionTests (16 tests, 0 failures)

| 用例 | 类别 | 结果 |
|------|------|------|
| testUngroupedReorderCommittedOnDrop | 正常 | PASS |
| testGroupedReorderCommittedOnDrop | 正常 | PASS |
| testGroupedReorderUpdatesDisplayedOrder | 正常 | PASS |
| testCancelRestoresUngroupedOrder | 意外 | PASS |
| testCancelRestoresGroupedOrder | 意外 | PASS |
| testSourceClosedDuringDragDoesNotDuplicateOrLose | 意外 | PASS |
| testTargetClosedDuringDragRestoresSafely | 意外 | PASS |
| testSingleTabReorderIsNoOp | 边界 | PASS |
| testInvalidTabIDBeginIsNoOp | 边界 | PASS |
| testMoveToFirstPosition | 边界 | PASS |
| testMoveToLastPosition | 边界 | PASS |
| testRepeatedEnterSameTargetIsIdempotent | 边界 | PASS |
| testPreviewThenRollbackLeavesNoTrace | 边界 | PASS |
| testCommitClearsPendingState | 边界 | PASS |
| testCrossGroupPreviewDoesNotCommit | 边界 | PASS |
| testCancelPendingReorderRestoresOrderWithoutCallerSnapshot | 意外 | PASS |

#### UnifiedWorkspaceChromeLayoutTests (7 tests, 0 failures)

- 包含尾部 80pt 空白拖窗区与页签区不重叠的布局检查。

#### 复核补救测试（2026-09-17）

`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -destination 'platform=macOS' -only-testing:PandaSSH-macOSTests/WorkspaceChromeEventBridgeTests -only-testing:PandaSSH-macOSTests/UnifiedWorkspaceChromeLayoutTests -only-testing:PandaSSH-macOSTests/WorkspaceTabDragTransactionTests test`

- 结果：35 个测试通过，0 个失败。
- 新增 `testCancelPendingReorderRestoresOrderWithoutCallerSnapshot`：证明未提交的排序可由 Store 自主回滚。
- 新增 `testBlankDragViewOwnsMouseDownInsteadOfPassingItToWindow` 与 `testSingleClickOnBlankAreaStartsExplicitWindowDrag`：证明空白区不再依赖上层事件透传，而是显式调用系统窗口拖动。
- 实现使用 `NSWindow.performDrag(with:)` 保留系统的空间切换等窗口拖动语义；空白区的拖窗视图改置于 SwiftUI 覆盖层，确保它成为该空白区的命中目标。

#### 页签栏空白区补救测试（2026-09-17）

先运行 `TabStripViewportStateTests`，因缺少 `trailingEmptyWidth` 而编译失败；实现后以独立 DerivedData 全量重新编译并运行：

`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -destination 'platform=macOS' -derivedDataPath /private/tmp/panda-ssh-chrome-green -only-testing:PandaSSH-macOSTests/TabStripViewportStateTests -only-testing:PandaSSH-macOSTests/WorkspaceChromeEventBridgeTests -only-testing:PandaSSH-macOSTests/WorkspaceTabDragTransactionTests test`

- 结果：43 个测试通过，0 个失败。
- 未溢出时，页签文档后的剩余空间不再属于 `ScrollView`，而是独立的 `WindowDragView` 区域；溢出时保留外层尾部拖窗区。

### 人工验收清单

以下项目需要启动应用后手动验证：

- [ ] **正常：拖动页签到另一位置** — 页签顺序更新且显示一致
- [ ] **正常：双击顶部空白区** — 窗口执行缩放操作
- [ ] **正常：再次双击空白区** — 窗口还原到原始大小
- [ ] **意外：拖动页签后拖出页签栏释放** — 页签顺序恢复
- [ ] **意外：双击页签** — 不触发窗口缩放
- [ ] **意外：双击关闭按钮** — 只关闭页签，不缩放窗口
- [ ] **意外：双击侧栏按钮** — 只触发按钮操作，不缩放窗口
- [ ] **边界：窄窗口** — 空白区仍支持拖窗
- [ ] **边界：侧栏显隐切换** — 空白区位置正确更新
- [ ] **边界：全屏切换** — chrome 行为正确

### 回归测试（2026-09-20）

`xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -destination 'platform=macOS' -only-testing:PandaSSH-macOSTests/WorkspaceChromeEventBridgeTests -only-testing:PandaSSH-macOSTests/UnifiedWorkspaceChromeLayoutTests -only-testing:PandaSSH-macOSTests/WorkspaceTabDragTransactionTests -only-testing:PandaSSH-macOSTests/TabStripViewportStateTests test`

- 结果：62 个测试通过，0 个失败。
- 四个目标测试套件全部绿：WorkspaceChromeEventBridgeTests (12)、WorkspaceTabDragTransactionTests (16)、UnifiedWorkspaceChromeLayoutTests (7)、TabStripViewportStateTests (27)。

#### Rust 测试与覆盖率门禁（2026-09-20）

- `cargo test`：全绿（panda-core + panda-ffi 全部 bin/lib/integration/doc tests）。
- `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`：
  - lines 覆盖率 95.82% ≥ 95% ✓
  - regions 覆盖率 94.50% < 95% ✗（**既有问题**，低 regions 文件为 `panda-ffi/src/ffi_sessions.rs` 83.10%、`panda-ffi/src/batch_transfer.rs` 85.00%、`panda-core/src/ssh.rs` 92.13%，均不在本变更范围内；本变更仅修改 Swift 文件，不涉及 Rust 业务逻辑）

### 人工验收清单

以下项目需要启动应用后手动验证：

- [ ] **正常：拖动页签到另一位置** — 页签顺序更新且显示一致
- [ ] **正常：双击顶部空白区** — 窗口执行缩放操作
- [ ] **正常：再次双击空白区** — 窗口还原到原始大小
- [ ] **意外：拖动页签后拖出页签栏释放** — 页签顺序恢复
- [ ] **意外：双击页签** — 不触发窗口缩放
- [ ] **意外：双击关闭按钮** — 只关闭页签，不缩放窗口
- [ ] **意外：双击侧栏按钮** — 只触发按钮操作，不缩放窗口
- [ ] **边界：窄窗口** — 空白区仍支持拖窗
- [ ] **边界：侧栏显隐切换** — 空白区位置正确更新
- [ ] **边界：全屏切换** — chrome 行为正确

### 结论

自动化测试全部通过（Rust cargo test 全绿，macOS XCTest 62/62 通过）。lines 覆盖率达标（95.82%）；regions 覆盖率 94.50% 未达标但属于既有问题，与本变更无关（本变更仅修改 Swift 侧 macOS chrome 与页签拖放逻辑，未触及 Rust 代码）。人工验收清单待用户在真机执行。
