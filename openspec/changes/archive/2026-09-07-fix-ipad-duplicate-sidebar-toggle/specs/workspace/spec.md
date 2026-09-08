## ADDED Requirements

## Requirement: iPad 侧栏恢复入口唯一
iPad 工作区 SHALL 保留系统导航提供的侧栏恢复入口。统一页签栏 MUST NOT 重复绘制自定义恢复按钮，也 MUST NOT 为该按钮预留宽度。

#### Scenario: 隐藏和恢复侧栏
- **WHEN** 用户隐藏侧栏或反复切换侧栏显隐
- **THEN** 仅保留系统提供的恢复入口，页签栏不显示重复按钮

#### Scenario: 紧凑宽度
- **WHEN** iPad 旋转或进入窄分屏
- **THEN** 页签栏不为自定义恢复按钮占位，系统导航入口保持可用
