## ADDED Requirements

### Requirement: SFTP 远程面板根目录由运行时解析

SFTP 双栏 SHALL 使用服务器返回的会话初始工作目录作为远程面板根目录；解析失败时 SHALL 回退到 `/`。

#### Scenario: 连接到非标准 home 路径的服务器

- **GIVEN** 服务器实际 home 目录为 `/share/CACHEDEV1_DATA/homes/lwq`
- **WHEN** 打开该主机的 SFTP 标签页
- **THEN** 远程面板根目录显示 `/share/CACHEDEV1_DATA/homes/lwq`
