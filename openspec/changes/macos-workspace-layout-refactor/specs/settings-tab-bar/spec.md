## Purpose

定义设置页中「标签页」标签内的页签栏配置能力：提供溢出模式选项、可视化预览，并在 App 重启后生效。

## ADDED Requirements

### Requirement: 设置页提供「标签页」标签

macOS 端设置页 SHALL 包含一个「标签页」设置标签（与「通用」「外观」「连接」「终端」「高级」并列）。点击后展示与页签栏相关的配置项。iPadOS 端 SHALL 不显示该标签。

#### Scenario: 打开 macOS 设置页

- **WHEN** 用户在 macOS 打开设置页
- **THEN** 可见「标签页」设置标签

#### Scenario: 打开 iPadOS 设置页

- **WHEN** 用户在 iPadOS 打开设置页
- **THEN** 设置页中不出现「标签页」标签

### Requirement: 标签页溢出模式选项

macOS 端「标签页」设置标签内 SHALL 包含「标签页溢出模式」配置项，提供两个单选选项：「左右滚动（默认）」与「溢出扩展显示」。选项下方 SHALL 显示当前模式的视觉预览图。用户切换选项后 SHALL 持久化，并在下次启动应用时生效。

#### Scenario: 默认模式为左右滚动

- **GIVEN** 用户首次安装 App 或从未修改过该设置
- **WHEN** 用户打开「标签页」设置标签
- **THEN** 「左右滚动（默认）」被选中，预览图显示单行页签与左右滚动按钮

#### Scenario: 用户切换为扩展显示

- **GIVEN** 用户当前处于「左右滚动」模式
- **WHEN** 用户在设置页选择「溢出扩展显示」
- **THEN** 单选项更新为「溢出扩展显示」，预览图显示多行页签，设置被持久化

#### Scenario: 设置下次启动生效

- **GIVEN** 用户已切换为「溢出扩展显示」
- **WHEN** 用户关闭并重新打开 App
- **THEN** 主窗口页签栏以「溢出扩展显示」模式渲染

### Requirement: 设置持久化

标签页溢出模式 SHALL 持久化到 `UserDefaults`，App 重启后保持用户最后一次选择。

#### Scenario: 重启 App 后保持设置

- **GIVEN** 用户已选择「溢出扩展显示」模式
- **WHEN** 用户关闭并重新打开 App
- **THEN** 主窗口页签栏仍以「溢出扩展显示」模式渲染

### Requirement: 非法值回退

若 `UserDefaults` 中存储了非法的溢出模式值，系统 SHALL 回退到默认的「左右滚动」模式。

#### Scenario: UserDefaults 值为非法字符串

- **GIVEN** `UserDefaults` 中 `tabBarOverflowMode` 为非法值
- **WHEN** App 启动读取该设置
- **THEN** 系统使用默认的「左右滚动」模式
