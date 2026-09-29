## Purpose

SSH 跳板机（Proxy Jump）连接能力：通过引用已有主机配置作为跳板，经 `direct-tcpip` 通道建立到目标主机的 SSH 连接。支持多级跳板递归引用，每跳独立进行主机密钥校验和认证。

## ADDED Requirements

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
