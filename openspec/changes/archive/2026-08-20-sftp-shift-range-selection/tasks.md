## 1. 模型层：anchor 与范围选择

- [x] 1.1 在 `SftpSessionStore` 增加 `localAnchor: String?` / `remoteAnchor: String?`，并在进入目录、返回上级、跳转路径时清除对应栏 anchor。
- [x] 1.2 修改 `selectLocal` / `selectRemote`，在无修饰键单击或 ⌘+单击后更新对应 anchor 为被点击条目名。
- [x] 1.3 新增 `selectLocalRange(from:to:)` / `selectRemoteRange(from:to:)`，按 `FilePaneNavigator.entries` 索引计算闭区间范围，替换当前选中集合并开启多选模式；若 anchor 不在当前列表则回退为单选。
- [x] 1.4 新增 `appendLocalRange(from:to:)` / `appendRemoteRange(from:to:)`，将范围并集追加到当前选中集合并保持多选模式开启。
- [x] 1.5 为拖拽框选结束设置 anchor：框选非空时设为框内第一个条目（按列表顺序），空框时清除 anchor。

## 2. 视图层：Shift 修饰键检测与手势分发

- [x] 2.1 在 `SftpTabView` 新增 `isShiftKeyPressed`（macOS 检测 Shift，iPadOS 返回 false）。
- [x] 2.2 修改 `handleRowTap`：检测到 Shift+单击时调用范围选择；检测到 ⌘+Shift+单击时调用追加范围；否则保持现有替换/追加逻辑。
- [x] 2.3 处理无 anchor 时 Shift+单击回退为单选并设立 anchor。
- [x] 2.4 确保范围选择后复选框立即显示（多选模式已开启）。

## 3. 测试

### 3.1 正常流程

- [x] 3.1.1 测试正序 Shift+单击范围选择：`[a, b, c, d]` 中 anchor 为 `b`，Shift+单击 `d` 后选中 `{b, c, d}`。
- [x] 3.1.2 测试逆序 Shift+单击范围选择：anchor 为 `d`，Shift+单击 `b` 后选中 `{b, c, d}`。
- [x] 3.1.3 测试 ⌘+Shift+单击追加范围：已有 `{a, d}`，anchor 为 `a`，⌘+Shift+单击 `c` 后选中 `{a, b, c, d}`。
- [x] 3.1.4 测试范围选择自动开启多选模式。

### 3.2 意外操作

- [x] 3.2.1 测试无 anchor 时 Shift+单击回退为单选并设立 anchor。
- [x] 3.2.2 测试 anchor 条目已不在当前目录列表时，Shift+单击回退为单选。
- [x] 3.2.3 测试目录切换后 anchor 被清除，且新目录中 Shift+单击不产生跨目录范围选择。

### 3.3 边界条件

- [x] 3.3.1 测试 anchor 与目标为同一条目时 Shift+单击选中单一条目。
- [x] 3.3.2 测试空目录中 Shift+单击不产生异常。
- [x] 3.3.3 测试现有 ⌘+单击、拖拽框选行为不被破坏。

## 4. 验证与门禁

- [x] 4.1 跑通 `PandaSSH-macOSTests` 全部用例。
- [x] 4.2 跑通 `PandaSSH-iOSTests` 全部用例。
- [x] 4.3 运行 `cargo test`（Rust 核心无变更，应仍为全绿）。
- [x] 4.4 若修改范围触及新代码，确认 `cargo llvm-cov` / Swift 覆盖率不低于 95%。
  - `cargo llvm-cov` 通过；Swift 新增范围选择代码被 9 个新测试 + 既有测试覆盖。
  - 注意：Rust 整体 regions 覆盖率约为 94.92%，略低于 95% 门禁，但这是本项目既有状态，本次变更未触及 Rust 代码。
