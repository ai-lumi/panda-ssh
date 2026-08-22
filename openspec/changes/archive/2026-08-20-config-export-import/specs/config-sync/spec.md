## MODIFIED Requirements

### Requirement: 跨设备同步预留

系统 SHALL 保留未来恢复跨设备配置同步的扩展点：本地配置文件格式保持稳定，钥匙串引用 key 命名不变，不得在代码中引入与 iCloud KV 冲突的替代同步机制。在 iCloud 同步不可用期间，用户 SHALL 可通过导出/导入功能手动迁移配置。

#### Scenario: 未来启用 iCloud 同步

- **WHEN** 后续版本重新引入 iCloud KV 同步
- **THEN** 现有本地配置文件可直接作为同步基准，无需迁移格式

#### Scenario: 无 iCloud 时通过导出导入迁移

- **GIVEN** 用户有两台设备均未启用 iCloud 同步
- **WHEN** 用户在设备 A 导出配置，在设备 B 导入
- **THEN** 设备 B 获得与设备 A 一致的主机列表、分组与代码片段
