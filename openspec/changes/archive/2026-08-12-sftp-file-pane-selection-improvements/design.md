## Context

当前 SFTP 文件栏使用 SwiftUI `List(selection:)` 同时承担单选与高亮职责：

- 单选模式用 `Binding<String?>` 绑定到 `selectedLocal` / `selectedRemote`。
- 多选模式用 `Binding<Set<String>>` 绑定到 `selectedLocalItems` / `selectedRemoteItems`。
- 目录行附加了 `TapGesture(count: 2)` 用于双击进入，导致与 `List` 的单击选中产生手势竞争，表现为单击目录难以高亮。

`SftpSessionStore` 同时维护两套选中状态，视图层需要在两种模式间切换绑定，增加了互斥与同步的复杂度。参见 `apple/PandaSSH/Workspace/SftpTabView.swift` 与 `apple/PandaSSH/Workspace/SftpSessionStore.swift`。

## Goals / Non-Goals

**Goals：**
- 让文件栏的单选、多选、目录进入三种操作有清晰且不冲突的交互。
- 多选模式提供复选框作为选中状态的可视化反馈。
- macOS 端支持 `⌘` 键追加/取消多选，行为与 Finder 一致。
- macOS / iPadOS（接鼠标）支持拖拽框选多选。

**Non-Goals：**
- 不替换为系统原生文件选择器/浏览器（如 `NSOpenPanel` / `UIDocumentBrowserViewController`）。
- 不引入新的 Rust 核心能力或批量传输算法改动。
- 不支持键盘方向键、Space 选中、全选快捷键等后续可扩展能力。

## Decisions

### 1. 统一选中模型：用 `Set<String>` 表达所有选中状态

**决策**：无论单选还是多选，文件栏内部统一使用一个 `Set<String>` 保存当前高亮/选中的条目名。单选模式下集合大小最多为 1；多选模式下集合大小可以大于 1。

**理由**：
- 消除 `String?` 与 `Set<String>` 两套状态之间的同步问题。
- 单选模式下单击新条目自然就是“高亮新条目并取消其他高亮”，与 `Set` 的替换语义一致。
- 为 `⌘` 多选和框选提供一致的数据模型：它们只是以不同方式修改这个集合。

**实现要点**：
- 在 `SftpSessionStore` 中新增 `selectedLocalSet: Set<String>` 与 `selectedRemoteSet: Set<String>`，逐步替换原有的 `selectedLocal` / `selectedRemote`（或把后者作为集合 first 的兼容计算属性）。
- 多选模式继续复用同一集合，不再单独维护 `selectedLocalItems` / `selectedRemoteItems`。
- 视图层通过 `@Published` 集合驱动高亮与复选框状态。

### 2. 单选模式：单击整行高亮，双击目录进入

**决策**：单选模式下，文件与目录行都响应单击进行高亮；目录行同时响应双击进入子目录。

**理由**：
- 与 Finder / Files App 行为一致。
- 解决当前目录行因附加双击手势导致单击选中失效的问题。

**实现要点**：
- 去掉 `List(selection:)` 绑定，改为手动管理高亮：在 `fileRow` 上使用 `.onTapGesture` 处理单击，统一修改 `selectedXxxSet`。
- 目录行仍保留 `.simultaneousGesture(TapGesture(count: 2))` 用于进入目录，但把单击逻辑从 `List(selection:)` 中解耦，避免手势竞争。
- 行背景根据 `selectedXxxSet.contains(entry.name)` 显式设置高亮色，不依赖 `List` 的内置 selection 高亮。

### 3. 多选模式：每行显示复选框

**决策**：多选模式下，每行左侧显示 `Image(systemName: isSelected ? "checkmark.square.fill" : "square")` 样式的复选框图标，点击整行或图标切换选中。

**理由**：
- 明确表达多选状态，降低用户困惑。
- 与 iOS Files App、邮件 App 的多选模式一致。

**实现要点**：
- 在 `fileRow` 开头增加一个 `Button` 或 `Image`，根据 `entry.name` 是否在集合中切换图标。
- 点击复选框与点击整行共用同一切换逻辑：未选中则加入集合，已选中则移除。
- 目录行在多选模式下不再提供“进入”按钮，避免与复选框冲突；用户需先完成选择再退出多选模式进入目录。

### 4. macOS Command 键多选

**决策**：在 macOS 端，通过 `NSEvent.modifierFlags` 判断 `⌘` 键是否按下，决定单击是替换选中集合还是追加/移除。

**理由**：
- 这是 macOS 用户最熟悉的多选方式，无需显式进入“多选模式”。

**实现要点**：
- 在 `fileRow` 的单击处理中使用 `NSApp.currentEvent?.modifierFlags.contains(.command) == true` 判断。
- 按住 `⌘` 单击已选中条目 → 从集合移除；按住 `⌘` 单击未选中条目 → 加入集合。
- 未按 `⌘` 单击 → 清空集合并只加入当前条目。
- 该能力仅限 `#if os(macOS)`，iPadOS 纯触摸仍走显式多选模式。

### 5. 鼠标框选多选

**决策**：在 macOS 与 iPadOS（接鼠标）实现拖拽矩形选区。由于 SwiftUI 没有内置框选手势，使用平台相关代码捕获鼠标拖拽并计算选区覆盖的行。

**理由**：
- 框选是桌面文件管理器的基础交互，能显著提升批量选择效率。

**实现要点**：
- 在文件列表外层包裹一个 `ZStack`：底层为 `List`，上层为透明的拖拽捕获层。
- macOS：使用 `NSViewRepresentable` 或 `DragGesture` 捕获鼠标按下、移动、释放的坐标，转换为列表相对坐标。
- iPadOS（接鼠标）：使用 `UIPanGestureRecognizer` 或 SwiftUI `DragGesture`，识别为鼠标拖拽时（非触摸）同样处理。
- 为每行使用 `GeometryReader` 或预计算行框架，判断哪些行与选区矩形相交。
- 拖拽开始时：
  - 未按 `⌘` → 清空集合并仅框选当前区域。
  - 按住 `⌘` → 在已有选中集合基础上追加框选条目。
- 拖拽过程中实时绘制半透明选区矩形（`Rectangle().fill(.accent.opacity(0.15))`）。

**替代方案**：纯 SwiftUI `DragGesture` 实现。已排除，因为 SwiftUI 的 `DragGesture` 在 macOS 上无法可靠区分鼠标左键拖拽与触控板手势，且难以获取列表内绝对坐标。

## Risks / Trade-offs

- **[Risk] 去掉 `List(selection:)` 后失去部分原生可访问性/键盘导航支持**  
  → **Mitigation**：保留 `List` 作为容器，仅把 `selection` 绑定改为手动管理；继续使用 `.accessibilityLabel` 与 `.accessibilityValue` 描述选中状态。

- **[Risk] 框选需要获取每行几何信息，可能与动态行高、自适应布局冲突**  
  → **Mitigation**：先固定行高（当前 `.defaultMinListRowHeight(22)` 已接近固定），框选按统一行高和列表偏移量计算；后续若引入动态行高，再改用 `GeometryReader` 逐行缓存框架。

- **[Risk] `⌘` 键检测依赖 `NSApp.currentEvent`，在 SwiftUI 中可能偶尔为 nil**  
  → **Mitigation**：在单击手势的 `onEnded` 中读取事件；若无法读取，默认走“替换选中”行为，避免误追加。

- **[Risk] iPadOS 接鼠标时框选与触摸滚动手势冲突**  
  → **Mitigation**：框选手势仅识别鼠标/触控板输入源；触摸操作不触发框选，避免影响正常滚动。

- **[Trade-off] 多选模式下无法直接“进入目录”**  
  复选框模式与进入目录操作互斥，用户需先退出多选模式再进入目录。这与 iOS Files App 的多选行为一致，属于可接受的取舍。
