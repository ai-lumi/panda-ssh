## ADDED Requirements

### Requirement: 主机搜索 FFI

系统 SHALL 通过 FFI 暴露 `search_hosts(query)` 接口，返回匹配的主机列表。搜索 SHALL 对主机的名称、地址、用户名进行大小写不敏感的模糊匹配，并 SHALL 对主机所属分组的完整路径进行匹配。空查询 SHALL 返回全部主机。

#### Scenario: 名称匹配

- **GIVEN** 存在主机「生产服务器」地址 10.0.0.1
- **WHEN** 调用 `search_hosts("生产")`
- **THEN** 返回包含该主机

#### Scenario: 分组路径匹配

- **GIVEN** 主机 h1 属于分组「生产 / 华东」
- **WHEN** 调用 `search_hosts("华东")`
- **THEN** 返回包含 h1

#### Scenario: 空查询返回全部

- **GIVEN** 存在 3 台主机
- **WHEN** 调用 `search_hosts("")`
- **THEN** 返回全部 3 台主机

#### Scenario: 大小写不敏感

- **GIVEN** 存在主机用户名 `Admin`
- **WHEN** 调用 `search_hosts("admin")`
- **THEN** 返回包含该主机

#### Scenario: 无匹配

- **WHEN** 调用 `search_hosts("不存在的关键词")`
- **THEN** 返回空列表
