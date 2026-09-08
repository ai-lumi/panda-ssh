## Context

见 proposal.md - Why。当前页签栏的滚动容器、页签 frame 缓存和装配代码分布在 `HorizontalWheelScrollView`、`WorkspaceTabBar` 与 `WorkspaceView`。现行规格要求它位于 detail 内容区，是为规避旧 principal toolbar item 的空间和事件竞争；同时系统工具栏必须保留以支持 macOS 26 侧栏融合。

## Goals / Non-Goals

**Goals:**

- 让标题栏页签区域拥有单一所有者，统一管理可见区、偏移、输入归一化、按钮状态和活动页签显露。
- 以 AppKit 处理窗口 chrome 几何和事件，以可独立装配的页签 UI 处理页签内容；不让 toolbar 的自动溢出参与页签导航。
- 保留旧内容区实现，允许同一页签数据模型在两条装配路径间无损切换。

**Non-Goals:**

- 不在此设计中规定后续移除旧路径的日期或条件。
- 不把 macOS titlebar host 扩展到 iPadOS，亦不改变页签业务模型。

## Decisions

### 1. 采用 AppKit 标题栏宿主与独立页签内容组件

新增 `MacOSTitlebarTabStripHost` 作为窗口 chrome 的唯一接触点：它观察窗口、工具栏、content layout rect 与侧栏可见性，计算可供页签容器使用的矩形，并负责装配/卸载宿主视图。新增独立的 `TitlebarTabStrip` 组件及纯值 `TabStripViewportState`，后者拥有内容宽度、可见宽度、偏移、边界、活动页签显露和滚动输入归一化。

理由：把标题栏坐标系和页签 viewport 规则分开，避免现有三层状态分散继续扩大。

替代方案：将 `WorkspaceTabBar` 放回 principal toolbar item。否决：历史提案已验证 toolbar 溢出会夺取宽度和事件，无法满足独立容器要求。

### 2. 先进行 AppKit 布局可行性探针，再接入生产路径

[未知] `NSTitlebarAccessoryViewController` 是否能在目标 macOS 版本上稳定提供仅限 detail 区的标题栏矩形，且同时避让红绿灯、系统侧栏恢复按钮和工具栏项目。第一阶段只建立可重复的 AppKit 布局探针与 XCTest/手工验收，测量常规、窄窗口、侧栏显示/隐藏、全屏四种状态；达不到规格时不得接入默认生产路径。

理由：此前 accessory 路径因对齐与重叠被移除，不能以假设替代验证。

替代方案：直接重建整个窗口或完全自绘标题栏。否决：会破坏系统工具栏驱动的侧栏融合，且重构面超过本变更必要范围。

### 3. 双路径装配，不删除旧实现

新增 macOS 页签栏装配策略（标题栏/内容区），默认请求标题栏路径；宿主不可用、探针失败或显式禁用时选择现有内容区路径。两条路径读取同一个 `WorkspaceStore` 与 `AppModel`，切换仅更换显示容器，禁止触及页签或会话对象。

理由：满足快速回滚、对照和渐进验证；使 AppKit 几何风险与终端会话风险隔离。

替代方案：原地重写 `WorkspaceTabBar` 并删除旧实现。否决：无法进行行为对照，布局回归时回滚代价高。

### 4. 以设备语义而非固定倍率处理滚轮

`TabStripViewportState` 接收归一化输入：精确设备保留连续 point delta 和惯性；离散鼠标按一个页签步距推进，步距由当前可见页签的稳定尺寸推导并设上下限。所有输入与按钮最终调用同一 `scroll(to:)` 边界夹取路径。

理由：避免当前鼠标 delta 过小，也避免对触控板应用倍数后失控。

替代方案：把原始 delta 乘固定常数。否决：设备、滚轮设置和页签宽度变化都会使体验不可预测。

## Risks / Trade-offs

- [Risk] AppKit 标题栏可用矩形在 macOS 版本、侧栏状态或全屏状态下不稳定 → 先以布局探针为门槛；不通过时保持旧内容区路径为默认。
- [Risk] 双路径短期增加维护量 → 共享纯值 viewport 状态与页签数据输入，且为旧路径建立明确回退测试。
- [Risk] SwiftUI/AppKit 生命周期造成重复装配或悬挂 observer → 宿主使用显式 attach/detach 生命周期和弱引用；加入窗口关闭与反复切换测试。
- [Risk] 传统鼠标和触控板识别存在边缘设备 → 对输入归一化写纯值测试，并保留可记录但不含敏感数据的诊断事件。

## Migration Plan

1. 先合入不改变默认 UI 的标题栏几何探针、独立 viewport 逻辑和旧路径回归测试。
2. 探针满足验收条件后，接入独立标题栏容器，但保留内容区路径的明确开关。
3. 在 macOS 目标版本验证标题栏与回退路径后，将标题栏路径设为默认；iPadOS 不迁移。
4. 回滚仅切回内容区路径并移除标题栏宿主的装配，不删除现有页签栏或页签数据。
