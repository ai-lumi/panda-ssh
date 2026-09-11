# 验证记录（2026-09-10）

## 根因与实现

`reportConnectionStatus` 仅写入 Rust，没有通知观察 `WorkspaceStore` 的 SwiftUI 页签与侧栏。状态查询已经正确，显示却依赖其他重绘事件。本次在实际状态变化前发送 `objectWillChange`，随即在同一主线程同步更新 FFI；重复状态与无效页签不发送通知。

生产代码新增一条重复状态保护、一条通知及其注释。保留本次开始前的 UUID/关闭修复及工作区其他未提交修改；不修改连接协议、会话状态机、颜色映射或 FFI。

## Verification

- TDD 红灯：6 项新增测试中 4 项失败、2 项通过，共 10 处通知断言失败。连接、失败、退出和 SFTP 的状态查询均正确，但观察通知始终为零。
- macOS：88 项相关测试执行完成，84 项通过、4 项失败。新增 6 项、23 项终端会话及 5 项重连测试全部通过。4 项失败均为页签标题序号空格/跨主机名称问题，与此前 `fix-workspace-tab-close-identity` 的 `green-workspace.log` 中失败名称完全一致，没有新增失败。
- iPadOS arm64 模拟器：应用和测试编译通过，6 项状态观察与 23 项终端会话测试全部通过（29/29）。
- `cargo test --offline`：489 项通过（含文档测试）、0 项失败、4 项真实服务器测试按原配置忽略。初次沙箱拒绝本地假服务器绑定回环端口，获准运行后通过。
- Swift 覆盖率：本次修改的 `reportConnectionStatus` 函数 14/14 行覆盖（100%），含其查询闭包。测试覆盖全部四种状态、相同状态、有效/未知/已关闭 ID。相关测试下整个 `WorkspaceStore.swift` 为 211/262 行（80.53%）；这不是全应用覆盖率，也不能据此声明全局 95% 门禁通过。
- Rust 源码未改，未重复测量 Rust 覆盖率。既有门禁记录为 lines 93.20%、regions 92.70%，低于项目 95% 门槛。本次不修改该门槛或扩大到无关覆盖率补齐，不执行提交。
- OpenSpec 严格校验、`git diff --check` 通过。此变更恢复现有规格，没有 delta 需要合并。

## Validation

测试使用真实工作区 FFI 与内存终端连接，验证状态变化直接产生 SwiftUI 观察通知、查询读取最新值、非活动页签退出不覆盖同主机其他连接，以及无需页签切换即可触发刷新。未连接真实 SSH 服务器，未操作用户窗口，未执行真实连接/`exit` 的人工视觉验收。

人工验收标准：新会话连通后状态点在下一次 UI 更新中由黄变绿；执行 `exit` 后由绿变红（当前既有断开颜色）；同主机其他已连接页签仍保持绿色，且侧栏在最后一个可用会话退出后不再表示已连接。

## 记录位置

本次日志和修改前备份位于 `/private/tmp/panda-tab-status-20260910/`：`red.log`、`green-macos.log`、`green-ios.log`、`cargo-test.log`、`swift-coverage.json` 与 `backup/`。新增测试位于 `WorkspaceStoreTests.swift` 的 `WorkspaceConnectionStatusObservationTests`。
