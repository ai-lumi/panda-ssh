## Context

页签选择按钮当前只包裹标题内容，外层容器的最小高度没有成为按钮命中范围。将一个 `Button` 包住关闭 `Button` 会形成嵌套控件，SwiftUI 的事件路由和辅助功能语义都不可靠。

## Decision

页签外层容器使用完整胶囊 `contentShape` 与选择手势。手势的包含范围仅为容器自身（不包括子视图），因此关闭 `Button` 维持独立命中与动作，不会传递为选择操作。容器补充按钮辅助功能 trait 与 activate action。

## Verification

XCTest 验证两个平台均声明父手势不包含子视图；视图引用该规则，并将完整胶囊作为父容器的命中形状。
