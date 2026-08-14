## Context

SFTP 文件栏的框选实现依赖两个坐标：
1. `DragGesture` 在 `filePaneSpace` 命名坐标空间中产生的 `startLocation` / `location`，用于绘制蓝色选区矩形。
2. 每行通过 `GeometryReader` 在 `filePaneSpace` 中上报的 `CGRect`，用于判断选区覆盖了哪些条目。

当前实现把这两个坐标系都绑定在 SwiftUI `List` 上。但 `List` 内部存在 content inset（plain style 在 macOS 上的默认顶部留白），使得 `GeometryReader` 获取的行 frame 与 `DragGesture` 返回的位置不在同一原点，导致选区矩形和真实命中条目错位。详见 [proposal.md](proposal.md)。

## Goals / Non-Goals

**Goals:**
- 让拖拽选区矩形与框选计算使用一致的坐标系。
- 保持现有交互不变：单击选中、双击进入目录、Command 追加、多选复选框、空目录提示、选区矩形可视化。
- 双端构建与单元测试保持通过。

**Non-Goals:**
- 不改写 `sftp-batch-transfer` 规范。
- 不引入新的框选手势或修改选择模型 API。
- 不调整批量传输后端逻辑。

## Decisions

### 1. 用 `ScrollView + LazyVStack` 替换 `List`

**理由**：`ScrollView + LazyVStack` 不会引入 `List` 的默认 content inset，`DragGesture` 与 `GeometryReader` 在同一个命名坐标空间中的原点一致，从根本上消除坐标错位。

**替代方案**：保留 `List`，尝试将 `coordinateSpace` 上提到 `pane` 层级，或在行上使用 `anchorPreference` 获取相对于屏幕的锚点。但 `List` 的内部坐标变换是黑盒，无法保证在不同 macOS 版本、字体大小、行高下都稳定对齐；`ScrollView + LazyVStack` 更简单且可预测。

### 2. 行高与间距保持原视觉

- 用 `.padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))` 替代原来的 `.listRowInsets`，保持行内边距一致。
- 用 `.frame(minHeight: 22)` 替代 `.environment(\.defaultMinListRowHeight, 22)`，保持最小行高。
- `LazyVStack(spacing: 0)` 让行间距完全由 padding 控制，与原来 List 的视觉间距等效。

### 3. 在 `project.yml` 显式声明 scheme 并绑定测试 target

**理由**：当前 `project.yml` 未声明 `schemes`，xcodegen 虽然生成 scheme，但不会自动把测试 target 绑定到应用 scheme 上，导致命令行无法直接运行测试。显式声明后，`xcodebuild -scheme PandaSSH-macOS test` 即可运行对应测试。

**替代方案**：每次测试前手动在 Xcode 中配置 test target，但这不符合自动化与 CI 友好原则。

## Risks / Trade-offs

- **[Risk] `LazyVStack` 延迟加载导致不可见行 frame 未收集** → **Mitigation**：框选操作天然发生在可视区域内，且用户当前截图的问题集中在可见条目；若未来需要框选超出屏幕的条目，可改为 `VStack` 或增加滚动自动扩展选区，但当前场景下 `LazyVStack` 性能更优。
- **[Risk] 失去 `List` 的原生键盘导航/辅助功能** → **Mitigation**：文件栏当前未依赖 List 的键盘导航；如需后续增强，可在 `LazyVStack` 上自行添加焦点管理，属于可控范围。
- **[Risk] 双端视觉轻微差异** → **Mitigation**：保持行高、内边距、背景色与原 List 一致，且已通过 macOS/iOS 双端构建与单元测试验证。
