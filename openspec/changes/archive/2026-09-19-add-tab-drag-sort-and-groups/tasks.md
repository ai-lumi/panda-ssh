## 1. 数据模型与状态管理

- [x] 1.1 编写 `TabGroup` 模型单元测试：创建、命名、空分组判断（正常流程）；空名称处理（意外操作）；大量分组性能（边界条件）
- [x] 1.2 实现 `TabGroup` 结构体：`id: UUID`、`name: String`、`tabIDs: [UUID]`
- [x] 1.3 编写 `WorkspaceStore` 分组状态测试：创建分组、删除分组、重命名分组（正常流程）；删除不存在的分组（意外操作）；空分组自动清理（边界条件）
- [x] 1.4 在 `WorkspaceStore` 中添加分组状态：`@Published groups: [TabGroup]`、`@Published ungroupedTabIDs: [UUID]`、`displayedTabs` 计算属性
- [x] 1.5 编写排序映射测试：`displayOrder` 维护、新页签追加、关闭页签移除（正常流程）；拖拽到无效位置（意外操作）；单页签排序（边界条件）
- [x] 1.6 在 `WorkspaceStore` 中实现排序映射：`displayOrder: [UUID]`，`syncFromFfi()` 后同步更新

## 2. 拖拽排序

- [x] 2.1 编写拖拽排序逻辑测试：移动页签到前/后位置（正常流程）；拖拽不存在的页签（意外操作）；首尾页签拖拽（边界条件）
- [x] 2.2 实现拖拽排序核心逻辑：`moveTab(from:to:)` 方法，更新 `displayOrder`
- [x] 2.3 编写页签栏拖拽 UI 测试：`.onDrag` 提供页签 ID、`.onDrop` 触发排序（正常流程）；拖拽取消（意外操作）；单页签无法拖拽（边界条件）
- [x] 2.4 在 `UnifiedWorkspaceTabStrip` 中实现拖拽手势：`.onDrag` 返回 `NSItemProvider`、`.onDrop` 处理排序

## 3. 分组操作

- [x] 3.1 编写分组操作测试：创建分组并分配页签（正常流程）；将页签移到已有分组（意外操作）；空分组创建（边界条件）
- [x] 3.2 实现分组操作方法：`createGroup(name:)`、`deleteGroup(id:)`、`moveTab(_:toGroup:)`、`removeTabFromGroup(_:)`
- [x] 3.3 编写关闭页签级联测试：关闭分组最后一个页签后分组自动删除（正常流程）；关闭未分组页签（意外操作）；关闭后分组为空（边界条件）
- [x] 3.4 在 `WorkspaceStore.close(tabID:)` 中添加级联逻辑：关闭后检查分组是否为空，空则删除

## 4. 右键菜单扩展

- [x] 4.1 编写右键菜单项测试：新建分组、移动到分组、未分组、删除分组（正常流程）；无分组时菜单项状态（意外操作）；单页签菜单（边界条件）
- [x] 4.2 在 `TabContextMenuBuilder` 中添加分组菜单项定义
- [x] 4.3 在 `TabMenuActionHandler` 中实现分组菜单动作（macOS）
- [x] 4.4 在 `tabContextMenuContent` 中实现分组菜单动作（iPadOS）

## 5. 分组视觉呈现

- [x] 5.1 编写分组渲染测试：分组标签显示、分隔符位置（正常流程）；无分组时不显示分隔（意外操作）；单分组（边界条件）
- [x] 5.2 在 `UnifiedWorkspaceTabStrip` 中实现分组视觉：分组标签、分隔符、背景色块
- [x] 5.3 实现拖拽视觉反馈：被拖拽页签半透明、插入位置指示器

## 6. 集成与同步

- [x] 6.1 编写 `syncFromFfi` 同步测试：新增页签追加到 `displayOrder` 末尾（正常流程）；Rust 侧页签被外部关闭（意外操作）；首次同步（边界条件）
- [x] 6.2 更新 `syncFromFfi()` 确保排序映射与 Rust 侧一致
- [x] 6.3 编写快捷键兼容性测试：Cmd+Tab 切换不受排序影响（正常流程）；关闭活动页签后选择左侧（边界条件）
- [x] 6.4 确保 `selectNextTab`/`selectPreviousTab` 使用 `displayedTabs` 顺序

## 7. 覆盖率与回归

- [x] 7.1 运行覆盖率检查：`cargo test` 全绿，Swift 测试 `lines >= 95%`、`regions >= 95%`
- [x] 7.2 运行现有 `WorkspaceStoreTests` 确保无回归
- [x] 7.3 手动验证 macOS 端拖拽排序和分组功能
- [x] 7.4 手动验证 iPadOS 端拖拽排序和分组功能

## 8. macOS 窗口拖动冲突修复

- [x] 8.1 修复页签拖拽与窗口拖动事件冲突：确保拖拽页签时不触发窗口移动
- [x] 8.2 确保标题栏空白区域仍可拖动窗口
- [x] 8.3 在无其他未完成工作区改动导致测试 target 编译失败时，运行 macOS 回归测试，验证页签拖放与空白区窗口拖动。
