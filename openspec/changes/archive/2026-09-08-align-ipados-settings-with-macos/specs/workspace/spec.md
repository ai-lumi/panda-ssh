## MODIFIED Requirements

### Requirement: 页签栏溢出显示模式

macOS 与 iPadOS 页签栏 SHALL 支持两种溢出显示模式：左右滚动（默认）与多行显示。用户 SHALL 在「设置 → 外观」中选择模式，选择结果 SHALL 持久化并在下次启动时生效。页签栏高度 SHALL 根据当前模式的内容自适应，MUST NOT 使用固定高度。

#### Scenario: iPadOS 设置入口提供页签栏模式

- **GIVEN** 用户在 iPadOS 的工作区侧栏中打开「设置」
- **WHEN** 用户切换到「外观」标签
- **THEN** 系统 SHALL 显示「页签栏溢出模式」设置，并提供与 macOS 相同的模式选项

#### Scenario: iPadOS 切换模式立即生效

- **GIVEN** iPadOS 工作区已打开若干页签
- **WHEN** 用户在「设置 → 外观」中切换页签栏溢出模式
- **THEN** 页签栏 SHALL 立即按新模式渲染，无需重启 App
