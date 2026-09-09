## ADDED Requirements

### Requirement: 旧版页签溢出设置退役

设置页 MUST NOT 显示仅供旧版使用的溢出模式选项或预览。应用 MUST NOT 读取、写入或清除旧版溢出模式 UserDefaults；历史值不影响统一页签栏。

#### Scenario: 旧偏好保留

- **WHEN** 已有多行显示偏好、非法值或未设置该偏好的用户打开应用
- **THEN** 均使用统一单行页签容器，设置页不再提供失效选项

## REMOVED Requirements

### Requirement: 设置页提供「标签页」标签

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 标签页溢出模式选项

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 设置持久化

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。

### Requirement: 非法值回退

**Reason**: 统一顶部 UI 已验收，旧版布局或配置退役。

**Migration**: 使用统一页签容器及当前侧栏入口；历史偏好保留但不再读取。
