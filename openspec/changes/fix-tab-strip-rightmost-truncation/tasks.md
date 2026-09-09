## 1. 回归测试

- [ ] 1.1 在 `TabStripViewportStateTests` 中先添加失败用例：宽于视口的最右页签在目标偏移接近内容右边界时，`scrollTarget` 应返回接近 trailing 的 anchorX。
- [ ] 1.2 补充宽页签中间偏移用例，验证 anchorX 按线性插值计算。
- [ ] 1.3 补充窄于视口页签用例，验证回退到 leading anchorX。
- [ ] 1.4 补充 `contentWidth(from:)` 用例，验证包含尾部 padding 且空页签返回 0。

## 2. 最小修复

- [ ] 2.1 在 `TabStripViewportState` 中实现 `contentWidth(from:trailingPadding:)`，使内容宽度与 ScrollView 实际内容边界一致。
- [ ] 2.2 在 `TabStripViewportState` 中实现 `scrollTarget(for:among:)`，页签宽于视口时返回插值 anchorX，否则返回 0（leading）。
- [ ] 2.3 在 `UnifiedWorkspaceTabStrip` 中使用 `TabStripViewportState.contentWidth(from:)` 计算 `currentViewport` 的 `contentWidth`。
- [ ] 2.4 在 `UnifiedWorkspaceTabStrip.scroll(to:using:animated:)` 中使用 `scrollTarget` 返回的自适应 anchor 替换固定 `.leading`。

## 3. 规格同步

- [ ] 3.1 在 `openspec/specs/unified-workspace-chrome/spec.md` 的“工作区使用统一的顶部 chrome 与独立页签容器” Requirement 下新增“最右侧页签完整显露” Scenario。
- [ ] 3.2 在 `openspec/changes/fix-tab-strip-rightmost-truncation/specs/unified-workspace-chrome/spec.md` 中保留规格增量。

## 4. 验证

- [ ] 4.1 运行 `TabStripViewportStateTests`，确认新增用例先失败后通过，既有测试保持通过。
- [ ] 4.2 运行 macOS XCTest target，确保统一页签栏相关测试无回归。
- [ ] 4.3 执行 `xcodebuild` 编译 macOS 与 iOS target，确认 Swift 侧无编译错误。
