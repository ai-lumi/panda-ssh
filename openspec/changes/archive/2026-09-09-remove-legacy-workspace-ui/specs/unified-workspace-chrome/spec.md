## ADDED Requirements

### Requirement: 验收后仅保留统一工作区

应用 SHALL 仅装配已验收的统一工作区 UI，MUST NOT 提供旧内容区页签栏或启停回退开关。页签选择、关闭确认与会话状态 SHALL 沿用共享 WorkspaceStore/AppModel。

#### Scenario: 打开工作区

- **WHEN** 用户打开工作区
- **THEN** 系统按上述约束呈现统一 UI


## REMOVED Requirements

### Requirement: 旧内容区页签栏可回退

**Reason**: 用户已验收统一 UI 并批准删除旧版。

**Migration**: 仅使用统一顶部 chrome；共享页签状态和会话对象保持不变。
