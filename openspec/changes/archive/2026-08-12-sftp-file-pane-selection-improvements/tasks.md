## 1. 统一选中模型

### 测试

- [x] 1.1 编写 `SftpSessionStore` 集合选中测试：
  - 正常流程：单选模式下设置集合只保留一个选中项。
  - 意外操作：传入空集合时无当前选中。
  - 边界条件：多选模式下集合可容纳多个条目。

### 实现

- [x] 1.2 在 `SftpSessionStore` 中新增 `selectedLocalSet` / `selectedRemoteSet`，移除或降维原有的 `selectedLocal` / `selectedRemote`（作为集合首元素的兼容访问）。
- [x] 1.3 更新 `selectLocal` / `selectRemote` 等方法，使其操作集合而非可选字符串。
- [x] 1.4 更新 `toggleLocalMultiSelect` / `toggleRemoteMultiSelect`，复用同一集合并在模式切换时保留/清空选中状态。

## 2. 多选模式复选框

### 测试

- [x] 2.1 编写多选复选框状态测试：
  - 正常流程：进入多选模式后，选中项对应复选框为勾选状态。
  - 意外操作：未选中项不显示勾选。
  - 边界条件：空目录下进入多选模式不崩溃。

### 实现

- [x] 2.2 修改 `SftpTabView.fileRow`，在多选模式下于行首显示复选框图标。
- [x] 2.3 实现点击整行或复选框切换该项在 `selectedXxxSet` 中的成员关系。
- [x] 2.4 多选模式下目录行不再显示“进入”按钮，避免与复选框冲突。

## 3. 单选模式单击高亮与目录选中

### 测试

- [x] 3.1 编写单选高亮测试：
  - 正常流程：单击文件后该文件高亮，其他条目不高亮。
  - 意外操作：单击目录后该目录高亮，同时取消之前选中文件的高亮。
  - 边界条件：双击目录后进入目录，选中集合清空。

### 实现

- [x] 3.2 在 `SftpTabView` 中去掉 `List(selection:)` 绑定，改为手动管理高亮背景。
- [x] 3.3 为文件行添加 `.onTapGesture` 处理单击，更新 `selectedXxxSet` 为单元素集合。
- [x] 3.4 保留目录行双击进入手势，确保单击与双击不冲突。
- [x] 3.5 根据 `selectedXxxSet.contains(entry.name)` 显式设置行高亮背景色。

## 4. macOS Command 键多选

### 测试

- [x] 4.1 编写 Command 键多选测试：
  - 正常流程：按住 `⌘` 单击两个文件，两个文件同时被选中。
  - 意外操作：未按 `⌘` 单击第三个文件，前两个文件被取消选中。
  - 边界条件：按住 `⌘` 再次单击已选中文件，该文件从选中集合移除。

### 实现

- [x] 4.2 在 `SftpTabView` 文件行单击处理中读取 `NSApp.currentEvent?.modifierFlags`，判断 `⌘` 键状态。
- [x] 4.3 实现 `⌘` 键下单击的追加/移除逻辑，非 `⌘` 键下单击的替换逻辑。
- [x] 4.4 用 `#if os(macOS)` 包裹平台相关代码，iPadOS 不受影响。

## 5. 鼠标框选多选

### 测试

- [x] 5.1 编写框选测试：
  - 正常流程：拖拽矩形覆盖三个文件，三个文件同时被选中。
  - 意外操作：框选区域未覆盖任何条目时，选中集合清空（未按 `⌘`）。
  - 边界条件：按住 `⌘` 框选时保留之前选中并追加新选中的条目。

### 实现

- [x] 5.2 在 `SftpTabView` 文件列表外层添加透明拖拽捕获层。
- [x] 5.3 macOS 端实现鼠标拖拽坐标捕获（`NSViewRepresentable` 或 `DragGesture`），转换为列表相对坐标。
- [x] 5.4 iPadOS 端接入鼠标时实现同等框选能力（`UIPanGestureRecognizer` 或 `DragGesture` 限定输入源为鼠标）。
- [x] 5.5 根据选区矩形与行框架计算相交条目，更新 `selectedXxxSet`。
- [x] 5.6 拖拽过程中实时绘制半透明选区矩形。

## 6. 验收与归档

- [x] 6.1 运行 `cargo test --workspace` 全绿。
- [x] 6.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过。
- [x] 6.3 运行 `apple/Scripts/build-rust.sh` 与 `xcodegen` 后，macOS / iOS 双端 `xcodebuild` 编译并通过测试。
- [x] 6.4 将本 change 的 spec delta 合并回 `openspec/specs/`。
- [x] 6.5 归档 change 到 `openspec/changes/` 的归档目录。
