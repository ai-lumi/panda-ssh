## Why

iPadOS 设置页目前仅显示「配置」和「关于」两个区段，而 macOS 使用「通用、外观、连接、终端、高级」标签页。两端设置内容与视觉层级不一致，且 iPadOS 无法访问 macOS 已提供的页签栏显示模式。

## What Changes

- iPadOS 设置页 SHALL 与 macOS 使用同一组设置标签、标签顺序、图标和各标签内容。
- iPadOS 的「外观」标签 SHALL 提供与 macOS 相同的页签栏显示模式设置。
- 文件导入/导出选择器仍使用各平台原生服务；密码保护、配置导入导出和设置持久化语义不变。

## Non-goals

- 不改变任何设置项的持久化格式、默认值或业务语义。
- 不改变 macOS 原生 Settings Scene 与 iPadOS 工作区侧栏入口的导航方式。
- 不实现占位标签之外的新连接、终端或高级设置功能。

## Capabilities

### Modified Capabilities

- `workspace`: 页签栏显示模式的设置入口从 macOS 扩展到 iPadOS。

## Impact

- `apple/PandaSSH/SettingsView.swift`：收敛平台布局差异，复用设置标签内容。
- `apple/PandaSSHTests/SettingsTabTests.swift`：锁定双端共享标签目录。
- `openspec/specs/workspace/spec.md`：将设置可用平台更新为 macOS 与 iPadOS。
