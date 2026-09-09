# settings-tab-bar Specification

## Purpose

记录统一页签栏验收后旧版配置的退役约束。应用不再暴露仅适用于旧内容区页签栏的多行显示及溢出模式选项，并明确历史偏好保持原值、不会参与统一页签容器的装配或布局。

## Requirements

### Requirement: 旧版页签溢出设置退役

设置页 MUST NOT 显示仅供旧版使用的溢出模式选项或预览。应用 MUST NOT 读取、写入或清除旧版溢出模式 UserDefaults；历史值不影响统一页签栏。

#### Scenario: 旧偏好保留

- **WHEN** 已有多行显示偏好、非法值或未设置该偏好的用户打开应用
- **THEN** 均使用统一单行页签容器，设置页不再提供失效选项

