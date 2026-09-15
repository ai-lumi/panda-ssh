# 验证记录（2026-09-10）

## 根因与修复

Swift `UUID.uuidString` 默认大写，Rust `Uuid::to_string()` 小写；现有工作区按字符串精确匹配。状态上报被忽略、已连接状态被误读，关闭操作先释放本地会话后又无法移除 Rust 页签，组合成用户报告的故障。

`WorkspaceStore` 已在传入 FFI 时统一小写，读取记录时比较 UUID 值。请求关闭保留确认门控；执行关闭先同步移除工作区页签，再精确释放注册会话。未改动 Rust、FFI 导出、页签 UI 或后台传输。

## Verification

- TDD 红灯：新增三个真实工作区 FFI 往返用例，在原生产实现上执行，三项全部失败，共 19 处断言失败。涵盖确认前提前断开、失败页不移除、重复释放及页签选择失效。
- 修复后 macOS 工作区及重连测试：59 项中 55 项通过；新增三个回归用例全部通过。剩余四项为标题序号空格和跨主机名称映射问题，对应 Rust 标题算法与主机名映射代码未在本次修改。
- macOS 全量：438 项用例执行完成，403 项通过、35 项失败，共 70 处失败断言。失败分布于选择状态、传输分组/速度、日志以及上述四项标题用例；未降低这些断言或删除测试。全量门禁未通过。修复前测试源码引用了已被工作区未提交改动移除的 checker 参数，未取得完整的修复前全量基线；其他模块未改动且不调用 WorkspaceStore，但本记录不将此替代完整基线对比。
- `cargo test --offline`：405 项通过，4 项真实服务器测试按原配置忽略。沙箱首次拒绝本地假服务器绑定回环端口，获准运行后通过；未连接真实服务器。
- Rust 覆盖率门禁未通过：lines 93.20%，regions 92.70%，低于 95%。本次没有修改 Rust 源码/测试，也没有降低覆盖率门槛。未计算 Swift 覆盖率。
- macOS 构建通过；iPadOS arm64 模拟器应用及测试构建通过。首次使用 generic simulator 默认同时构建 x86_64，与已有 arm64 Rust 模拟器库不匹配；改用现有支持架构后通过。
- iPadOS 模拟器的 8 项关闭回归测试全部通过：三个新增往返用例、批量确认全部/其他、批量取消、连接中直接关闭以及 SFTP 直接关闭。
- OpenSpec 严格校验通过；`git diff --check` 通过。

## Validation

回归测试使用真实工作区 FFI 与内存终端连接，验证确认、取消、最后页签、重复关闭、未知 ID、延迟状态上报和同主机其他会话保留。没有对真实 SSH 连接和系统警告框执行人工点击验收。

## 范围与待办

原有 TransferStore、UnifiedWorkspaceTabStrip、AuthTests、MacosWorkspaceChromeMetricsTests 及四个测试文件删除均保持原状；只在已有 WorkspaceStore 改动上叠加修复。相关测试改为通过实际 FFI 上报连接状态，并在每个用例前后重置全局工作区。

本次问题的实现与回归已完成，但全量测试及覆盖率门禁未通过，提案保留未归档，不执行 Git 提交。后续需要独立处理全量失败、补足覆盖率并完成真实窗口验收。

## 日志

日志位于 `/private/tmp/panda-tab-close-20260910/`：`red.log`、`green-workspace.log`、`macos-full.log`、`cargo-test.log`、`coverage.log`、`ios-build-arm64.log`、`ios-regression.log`。修改前工作区实现和原测试备份位于其 `backup/` 子目录。本次生成的 iOS DerivedData 已移至该临时目录，避免污染工作区。
