## Context

`SettingsView` 已共享通用、外观与占位标签的内容实现，但仅 macOS 将这些内容装入 `TabView`；iPadOS 单独渲染了通用表单，造成内容和视觉分叉。导入选择器与导出分享属于平台服务差异，必须继续保留条件编译。

## Goals / Non-Goals

**Goals:**

- 让双端使用单一、可测试的设置标签目录。
- 让 iPadOS 呈现与 macOS 相同的标签、顺序、图标及内容层级。
- 只在文件选择器、分享和 macOS Settings Scene 等平台服务/容器处保留差异。

**Non-Goals:**

- 不把 UI 导航或平台服务移入 Rust 核心。
- 不更改配置、密码保护或页签栏溢出模式的现有行为。

## Decisions

### 1. 用共享枚举定义设置标签目录

新增纯值 `SettingsTab`，集中定义标签标题、SF Symbol 和顺序。macOS 与 iPadOS 共同从该目录构建 `TabView`，避免日后只修改一个平台。

### 2. 保留平台容器差异，不保留内容差异

macOS 继续在原生 `Settings` Scene 中固定推荐窗口大小；iPadOS 继续由工作区侧栏路由到设置页并显示导航标题。二者内部使用相同的标签页和表单内容。`#if os()` 仅保留选择器样式与文件选择/分享服务。

## Risks / Trade-offs

- iPadOS 的标签项增加后可用宽度变窄；系统 `TabView` 会负责滚动/自适应，内容不使用固定像素宽度。
- 现有规格只描述 macOS 的设置入口；本变更的 spec delta 明确将其扩展到 iPadOS。

## Verification

- XCTest 验证设置标签目录的标题与图标顺序。
- 构建 macOS 与 iPadOS scheme，验证共享 SwiftUI 源码可分别编译。
- 手动验证 iPadOS 从侧栏进入设置后可访问五个标签，并确认外观选项即时影响工作区页签栏。
