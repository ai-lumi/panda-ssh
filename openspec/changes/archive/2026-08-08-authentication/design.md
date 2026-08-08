## Context

现有认证链路：`panda-core` 的 `Credentials::Password(String)` / `Credentials::KeyFile { path, passphrase }`，`SshSession::connect` 中 `authenticate_password` / `authenticate_publickey`（`load_secret_key`）。FFI 的 `credentials_for` 从 Swift 侧传入的 `password`/`passphrase` 参数构造 `Credentials`，密钥材料从不经 FFI 落盘。Swift 已有 `KeychainHelper.swift`（`kSecAttrSynchronizable` 同步钥匙串，App Group `com.pandassh.shared`）。缺口在：密码保存/读取、私钥文件选择、口令保存。

## Goals / Non-Goals

**Goals:**

- 密码与私钥口令可保存到同步钥匙串，登录时自动读取填充。
- 私钥文件可在 macOS（`NSOpenPanel`）与 iPadOS（`UIDocumentPicker`）上选择，路径写入主机配置。
- 所有密钥材料只存钥匙串，配置 TOML 只存 `*_ref` 引用，无明文落盘。
- 双端共享认证表单源码，仅文件选择器做平台分支。

**Non-Goals:**

- Secure Enclave / 钥匙串内托管私钥本身。
- 一次性口令、代理/跳板认证。
- Windows 凭据管理器等跨平台凭据存储。

## Decisions

### 钥匙串项设计与引用键

沿用现有 `AuthMethod` 的 `password_ref` / `passphrase_ref` 字段：`ref` 为扁平键 `host.<id>.password` / `host.<id>.passphrase`（与主 spec「凭据漫游」中级联删除的条目命名一致，避免写入与删除使用两套寻址）。`KeychainHelper` 提供 `save/read/delete(ref)` 封装，统一 `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable`（iCloud 同步）；按主 spec「凭据漫游」约束，SHALL NOT 设置显式 `kSecAttrAccessGroup`。

规则：当用户选择「保存密码」时，Swift 写入钥匙串并把生成的 `ref` 写入主机配置；不保存时 `ref` 为 `None`，登录需手动输入且不落盘。删除主机时按 `ref` 级联删除钥匙串条目（主 spec「凭据漫游」已规格化，本变更的 KeychainService 提供 `delete` 支撑）。

### 私钥选择

新增共享组件 `KeyPicker`：macOS 用 `NSOpenPanel`（可选 .pem/.key 等类型），iPadOS 用 `UIDocumentPicker(forOpeningContentTypes: [.item])`（安全作用域访问 + `startAccessingSecurityScopedResource`）。选择后把可访问的路径（iPadOS 上为拷贝到 App Group 容器后的本地路径，保证跨会话可用）写入 `AuthMethod::PublicKey.key_path`。

### 登录时凭据组装

Swift 在发起连接（`test_connection`/`sftp_*`/`shell_open`）前统一通过 `KeychainHelper` 解析主机认证方式：密码则读 `password_ref` 得到 `password`；密钥则传 `key_path`，若有 `passphrase_ref` 则读出口令作为 `passphrase`。无保存凭据时弹输入框，输入仅在内存中使用，不落盘。手动输入的密码按会话（标签页）独立持有：同一主机开多个标签页时各自弹框、互不共享（用户可能用不同账号登录），标签页关闭即销毁。

### 测试隔离

钥匙串通过 `KeychainService` 协议抽象（`save/read/delete`），Swift 测试注入内存 fake；文件选择器通过 `KeyPicker` 协议抽象，测试注入返回固定路径的 fake。

## Risks / Trade-offs

- [同步钥匙串在 iCloud 未登录/受限时行为不定] → `KeychainHelper` 读取失败时降级为「要求手动输入」，不阻塞连接。
- [iPadOS 安全作用域文件的跨会话可用性] → 选择后拷贝到 App Group 容器目录，避免安全作用域失效。
- [钥匙串保存失败不应导致无法登录] → 区分两条路径：**主机表单保存路径**写入钥匙串失败 MUST 阻止保存并以错误呈现（与主 spec「凭据漫游」一致，SHALL NOT 静默丢失凭据）；**登录时勾选「保存密码」路径**写入失败仅提示「密码未能保存到钥匙串」，本次连接仍用输入值继续，配置不写 `ref`（下次登录仍会询问，不产生悬空引用）。

## Migration Plan

旧配置若 `password_ref` 已存在则继续读取，无需迁移；新保存功能按上述规则写入。

## Open Questions

- 是否允许「查看已保存密码」？出于安全考虑当前不提供明文查看，仅提供「清除/重新保存」。
