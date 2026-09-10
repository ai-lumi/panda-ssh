# Spec Deltas：SSH 跳板机（Proxy Jump）

## 变更概览

本提案新增 SSH 跳板机能力，涉及 3 个现有规格的新增条款和 1 个新增规格文件。

---

## 1. host-config/spec.md

### 1.1 新增段落：主机配置数据模型

在现有 `### Requirement: 主机配置数据模型` 的字段列表中追加：

```
`proxy_jump`（可选，跳板机引用，指向另一台 `HostConfig` 的 id；缺省/缺失为 `None` 即直连）。
```

在现有 Scenario 列表末尾新增：

```markdown
#### Scenario: 含跳板机引用的配置序列化

- **WHEN** 一个 `proxy_jump` 指向有效 id 的 `HostConfig` 被序列化为 TOML 再反序列化
- **THEN** 结果与原始值相等，且 TOML 文本中 `proxy_jump` 字段为跳板机的 id 字符串

#### Scenario: 缺少 proxy_jump 字段的旧配置

- **WHEN** TOML 中的主机条目缺少 `proxy_jump` 字段
- **THEN** 反序列化结果 `proxy_jump` 为 `None`（直连）
```

### 1.2 新增 Requirement：跳板链校验

```markdown
### Requirement: 跳板链校验

系统 SHALL 在 HostConfig upsert 和配置加载时校验 `proxy_jump` 引用的合法性。校验 MUST 覆盖以下约束：

1. **悬空引用**：`proxy_jump` 引用的 id MUST 存在于同一配置存储；不存在时 MUST 返回 `DanglingProxyJumpRef` 错误。
2. **自引用**：`proxy_jump` MUST NOT 指向自身 id；违反时 MUST 返回 `SelfReferencingProxyJump` 错误。
3. **环检测**：沿 `proxy_jump` 递归遍历 MUST NOT 出现环；违反时 MUST 返回 `CyclicProxyJump` 错误，并携带环路径。
4. **最大链深**：跳板链深度 MUST NOT 超过 `MAX_PROXY_CHAIN_DEPTH`（8）；违反时 MUST 返回 `ProxyJumpChainTooDeep` 错误。

校验 SHALL 在 upsert 时先于持久化执行，MUST NOT 允许非法配置写入文件。

#### Scenario: 合法单跳引用

- **WHEN** 主机 A 的 `proxy_jump` 指向已存在的主机 B，且 B 无 `proxy_jump`
- **THEN** upsert 成功，校验通过

#### Scenario: 合法多级跳板引用

- **WHEN** A → B → C（C 无 `proxy_jump`），链深为 3
- **THEN** upsert 成功，校验通过

#### Scenario: 自引用拒绝

- **WHEN** 主机 A 的 `proxy_jump` 指向 A 自身的 id
- **THEN** upsert 被拒绝，返回 `SelfReferencingProxyJump` 错误

#### Scenario: 环引用拒绝

- **WHEN** A → B → C → A 形成环
- **THEN** upsert 被拒绝，返回 `CyclicProxyJump` 错误

#### Scenario: 超深链拒绝

- **WHEN** 跳板链深度为 9（超过上限 8）
- **THEN** upsert 被拒绝，返回 `ProxyJumpChainTooDeep` 错误

#### Scenario: 悬空引用拒绝

- **WHEN** `proxy_jump` 引用的 id 在配置存储中不存在
- **THEN** upsert 被拒绝，返回 `DanglingProxyJumpRef` 错误

#### Scenario: 边界——链深恰好等于上限

- **WHEN** 跳板链深度恰好为 8
- **THEN** upsert 成功，校验通过
```

### 1.3 新增 Requirement：删除约束

```markdown
### Requirement: 跳板机删除约束

系统 SHALL 在删除 `HostConfig` 时检查该 id 是否被其他主机的 `proxy_jump` 引用。被引用时 MUST 拒绝删除并返回 `ProxyJumpInUse` 错误，错误信息 MUST 包含引用方的 id 和 name 列表。此约束 MUST 在 `ConfigStore::delete` 层统一实施，覆盖所有调用入口（UI、导入、MCP）。

#### Scenario: 删除被引用的跳板机

- **WHEN** 主机 B 被主机 A 的 `proxy_jump` 引用，尝试删除 B
- **THEN** 删除被拒绝，返回 `ProxyJumpInUse` 错误，包含 A 的 id 和 name

#### Scenario: 删除未被引用的主机

- **WHEN** 主机 B 未被任何主机的 `proxy_jump` 引用
- **THEN** 删除正常成功

#### Scenario: 引用方已删除后可删除被引用方

- **WHEN** A 曾引用 B，A 已被删除后再删除 B
- **THEN** 删除正常成功
```

---

## 2. ssh-connection/spec.md

### 2.1 新增 Requirement：跳板机连接

```markdown
### Requirement: 跳板机连接

系统 SHALL 支持通过一级或多级跳板机建立 SSH 连接。当 `HostConfig.proxy_jump` 不为 `None` 时，连接流程 MUST：

1. 解析完整跳板链（从第一级跳板到目标主机）
2. 逐跳建立 SSH 连接：第一跳以 `TcpStream` 直连，后续跳通过前一跳的 `direct-tcpip` 通道承载
3. 每跳独立执行主机密钥校验（使用各跳自身的 `(host, port)`）
4. 每跳独立执行认证（使用各跳自身的凭据）
5. 任一跳失败时 MUST 关闭已建立的所有中间连接

跳板链中的中间会话生命周期 MUST 绑定到目标会话，目标会话释放时中间会话 MUST 自动关闭。

#### Scenario: 单跳代理连接

- **WHEN** 目标主机 A 的 `proxy_jump` 指向跳板机 B
- **THEN** 系统先连接 B，再通过 B 的 `direct-tcpip` 通道连接 A

#### Scenario: 多级跳板连接

- **WHEN** A → B → C → 目标 D（3 级跳板）
- **THEN** 系统依次连接 B、C、D，每级通过前一级的 `direct-tcpip` 通道

#### Scenario: 中间跳认证失败

- **WHEN** 跳板链中第 2 跳认证失败
- **THEN** 第 1 跳的连接被关闭，返回 `ProxyJumpFailed` 错误，携带失败跳的位置和原因

#### Scenario: 无跳板时行为不变

- **WHEN** `proxy_jump` 为 `None`
- **THEN** 连接流程与跳板机功能引入前完全一致

#### Scenario: 目标会话释放时中间会话关闭

- **WHEN** 目标会话被 Drop 或显式 disconnect
- **THEN** 所有中间跳板的会话也被关闭
```

### 2.2 新增 Requirement：每跳主机密钥校验

```markdown
### Requirement: 每跳主机密钥校验

跳板链中的每一跳 MUST 独立执行主机密钥校验。校验使用各跳自身的 `(host, port)` 和共享的 `KnownHosts`，策略由调用方统一传入。

- 跳板的 Unknown 密钥 MUST 返回 `ProxyJumpUnknownHostKey`，携带跳板位置信息、呈现密钥和指纹
- 跳板的 Mismatch 密钥 MUST 阻断连接，行为与直连时一致
- 目标主机的密钥校验行为与无跳板时完全一致

#### Scenario: 跳板机密钥未知

- **WHEN** 跳板机（第 1 跳）的密钥不在 known_hosts 中
- **THEN** 返回 `ProxyJumpUnknownHostKey`，携带 hop_index=0、跳板配置、呈现密钥和指纹

#### Scenario: 跳板机密钥变更

- **WHEN** 跳板机的密钥与 known_hosts 中存储的不匹配
- **THEN** 连接被阻断，返回 `HostKeyMismatch`，行为与直连时一致

#### Scenario: 多级跳板中第二跳密钥未知

- **WHEN** 第 1 跳密钥已确认，第 2 跳密钥不在 known_hosts 中
- **THEN** 第 1 跳连接保持，返回 `ProxyJumpUnknownHostKey`，携带 hop_index=1
```

### 2.3 新增 Requirement：每跳凭据

```markdown
### Requirement: 每跳凭据

跳板链中的每一跳 MUST 使用各自 `HostConfig` 的 `auth` 配置获取凭据。调用方 MUST 按链顺序提供 `Vec<Credentials>`，连接函数按位置对应使用。

凭据 MUST NOT 在跳板间共享或传递。凭据 MUST NOT 经 FFI 落盘。

#### Scenario: 混合认证方式

- **WHEN** 跳板机使用密码认证，目标主机使用密钥认证
- **THEN** 跳板机以密码认证通过，目标以密钥认证通过

#### Scenario: 凭据顺序与链一致

- **WHEN** 跳板链为 [B, C, 目标 A]
- **THEN** credentials[0] 用于 B，credentials[1] 用于 C，credentials[2] 用于 A
```

---

## 3. host-key-verification/spec.md

### 3.1 新增段落

在现有 `### Requirement: 连接期策略` 末尾新增说明：

```markdown
跳板链中的每跳使用相同的校验机制，但各跳以自身的 `(host, port)` 进行校验。跳板机的 Unknown 密钥通过 `ProxyJumpUnknownHostKey` 错误返回（携带跳板位置信息），UI 须逐跳展示指纹并要求用户确认。
```

---

## 4. 新增规格文件：proxy-jump/spec.md

```markdown
# proxy-jump Specification

## Purpose

SSH 跳板机（Proxy Jump）连接能力：通过引用已有主机配置作为跳板，经 `direct-tcpip` 通道建立到目标主机的 SSH 连接。支持多级跳板递归引用，每跳独立进行主机密钥校验和认证。

## Requirements

### Requirement: 跳板链解析

系统 SHALL 从目标主机的 `proxy_jump` 字段出发，递归解析完整跳板链。解析结果 MUST 为有序列表 `[跳板1, 跳板2, ..., 目标]`，连接时按此顺序逐跳建立。

解析过程中 MUST 执行防御性校验（环检测、深度检查），即使配置层已保证合法性。

#### Scenario: 无跳板时解析结果

- **WHEN** 目标主机 `proxy_jump` 为 `None`
- **THEN** 解析结果为 `[目标]`，长度为 1

#### Scenario: 单跳解析

- **WHEN** 目标 A 的 `proxy_jump` 指向 B，B 无 `proxy_jump`
- **THEN** 解析结果为 `[B, A]`

#### Scenario: 多级跳板解析

- **WHEN** A → B → C（C 无 `proxy_jump`）
- **THEN** 解析结果为 `[C, B, A]`

### Requirement: 失败清理

跳板链连接过程中任一跳失败时，系统 MUST 关闭所有已建立的中间连接。关闭顺序 MUST 为反序（最后建立的先关闭）。清理过程中的关闭失败 MUST NOT 掩盖原始错误。

#### Scenario: 第 2 跳失败时清理第 1 跳

- **WHEN** 第 1 跳连接成功，第 2 跳认证失败
- **THEN** 第 1 跳的连接被关闭，返回第 2 跳的错误

#### Scenario: 清理过程中的错误不掩盖原始错误

- **WHEN** 第 2 跳失败，关闭第 1 跳时也出错
- **THEN** 返回第 2 跳的原始错误，第 1 跳的关闭错误记录到日志

### Requirement: 配置导入导出

配置导入导出 MUST 正确处理 `proxy_jump` 引用：

1. **ID 重映射**：导入时若主机 id 因冲突需重新生成，所有引用该 id 的 `proxy_jump` MUST 同步更新
2. **悬空引用**：导入时 `proxy_jump` 引用的 id 不存在时 MUST 报错，MUST NOT 静默丢弃引用

#### Scenario: 导入时 ID 重映射

- **WHEN** 导入主机 B（被 A 的 `proxy_jump` 引用），B 的 id 与已有主机冲突需重新生成
- **THEN** B 获得新 id，A 的 `proxy_jump` 更新为新 id

#### Scenario: 导入时悬空引用报错

- **WHEN** 导入主机 A 的 `proxy_jump` 指向的 id 在目标存储中不存在
- **THEN** 导入报错，列出悬空引用，不静默将 A 改为直连
```

---

## 影响分析

### 兼容性

- **host-config**：新增可选字段，向后兼容；新增校验 Requirement，不影响现有合法配置
- **ssh-connection**：新增跳板连接 Requirement，`proxy_jump == None` 时行为不变
- **host-key-verification**：新增说明段落，不改变现有校验逻辑
- **proxy-jump（新增）**：独立规格文件，描述跳板链解析、失败清理和导入导出

### 测试影响

- 需要新增大量单元测试：配置校验、连接流程、失败清理、错误类型
- 需要 fake SSH server 支持 `direct-tcpip` 通道测试
- 覆盖率门禁：新增代码分支必须有测试覆盖

### FFI 影响

- `HostConfig` 新增字段通过 uniffi Record 自动导出
- 新增错误类型通过 uniffi Enum 自动导出
- 连接函数签名不变，跳板处理对 FFI 调用方透明

### 安全影响

- 每跳独立校验主机密钥，不跳过任何一跳
- 每跳独立认证，凭据不在跳板间共享
- 跳板链变化影响已审核计划的授权（与审计/授权提案联动）

---

## 迁移指南

无需数据迁移。`proxy_jump` 为可选字段，旧配置缺少此字段时按 `None`（直连）处理，无需修改已有配置文件。
