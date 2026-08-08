## Why

密码与密钥登录是 SSH 客户端的核心功能。核心库已支持两种认证（`Credentials::Password` / `Credentials::KeyFile`），FFI 也通过 `password`/`passphrase` 参数接收密钥材料，但缺少两件事：一是「保存密码/口令」——用户每次都要重新输入；二是「选择本地私钥」——macOS 与 iPadOS 上都需要可用的私钥选取交互。

## What Changes

- 支持密码认证登录，并允许将密码保存到系统钥匙串（iCloud 同步），配置仅存引用。
- 支持密钥认证登录，允许用户通过文件选择器选择本地私钥文件。
- 支持带口令的私钥，口令可选保存到钥匙串。
- 保存/修改/清除已保存的密码与口令。
- 登录时自动从钥匙串读取并填充，无需手动输入。
- 密钥材料（密码、口令）不落配置文件与日志，仅存钥匙串。

## Non-Goals

- 本变更不实现 Secure Enclave 私钥、钥匙串内直接托管私钥文件。
- 本变更不实现一次性口令、跳板机/代理等高级认证。
- 本变更不改变主机 CRUD 与指纹流程（属于 `server-management` 变更）。
- 本变更不实现 Windows 凭据管理器等非 Apple 平台的凭据方案。

## Capabilities

### New Capabilities

- `auth`: 密码认证（含密码保存）、密钥认证（含本地私钥选择）与密钥材料保护。

### Modified Capabilities

None.

## Dependencies

- 前置：`server-management`（主机表单骨架与连接入口的 `trust_on_first_use` 签名）。
- 被依赖：`tabbed-workspace`（`shell_open` 凭据组装遵循本变更的解析规则；手动密码按标签页持有的生命周期与标签页关闭对接）。

## Impact

- macOS 与 iPadOS 双端：密码/口令的保存与读取走 `KeychainHelper`（已存在）适配 `kSecAttrSynchronizable`；私钥选择在 macOS 用 `NSOpenPanel`、iPadOS 用 `UIDocumentPicker`，需在共享源码中做平台分支封装。
- Rust 核心（`crates/panda-core`）：认证链路已支持，无需改动核心逻辑；仅在需要时补充密钥类型与口令处理的健壮性测试。
- FFI（`crates/panda-ffi`）：认证相关签名已就绪（`password`/`passphrase` 参数传入），本变更主要工作在 Swift 侧钥匙串与文件选择，FFI 无破坏性改动。
- Swift UI：认证表单（密码框、保存开关、私钥选择）、钥匙串读写封装。
- 测试：Swift 侧钥匙串封装用 fake/mock 测试（不触碰真实钥匙串）；macOS/iPadOS 文件选择分支逻辑测试。
