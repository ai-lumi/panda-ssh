## 1. 回归测试

- [x] 1.1 先更新 macOS chrome 策略 XCTest 为失败断言：页签栏位于内容行而非 principal 工具栏，覆盖常规标签、零标签和大量标签的边界。
- [x] 1.2 为真实 `WorkspaceView` 增加失败的翻页回归测试，覆盖正常按页移动、切回起点，以及窄宽度下页签栏保留其自定义滚动容器。

## 2. macOS 页签栏布局

- [x] 2.1 修改 macOS chrome 策略与 `WorkspaceView`：保留系统工具栏，将页签栏置于 detail 内容区首行并移除 principal toolbar item。
- [x] 2.2 保持 iPadOS 页签栏、现有滚动/翻页算法和终端页签会话保持逻辑不变。

## 3. 验证

- [x] 3.1 运行新增与相关 macOS XCTest，确认正常翻页、意外的窄宽度和零/大量标签边界均通过。
- [x] 3.2 运行 macOS/iOS 构建、OpenSpec 严格校验及覆盖率门禁（lines/regions 均不低于 95%）。
