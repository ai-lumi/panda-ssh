## Context

当前 `ConfigSync.swift` 通过 `NSUbiquitousKeyValueStore` 在 macOS 与 iPadOS 间同步 hosts.toml/groups.toml 快照，`PandaCoreBackend` 在启动时 pull、保存后 push、并监听远端变更。`SettingsView` 有一个演示性质的 iCloud 同步开关。

个人开发者账号无法创建包含 iCloud KV + App Groups 的 iOS provisioning profile，导致 iOS 构建失败。因此本期彻底移除 iCloud 配置同步，但保留钥匙串的 `synchronizable` 属性作为无侵入保留（是否漫游由系统 iCloud Keychain 设置决定）。

## Goals / Non-Goals

**Goals:**
- 移除所有 iCloud KV 配置同步代码与配置
- 移除 Settings 页 iCloud 同步开关
- 让 iOS Debug 构建在个人开发者账号下无需 iCloud/App Groups entitlement 即可签名运行
- 同步更新相关规格与文档

**Non-Goals:**
- 不改钥匙串 `kSecAttrSynchronizable` 属性
- 不替代为其他同步方案
- 不改本地配置文件格式与落盘路径

## Decisions

### 决策 1：直接删除 ConfigSync.swift

**选择：** 删除整个 `Sync/ConfigSync.swift`，而不是只注释掉调用。

**理由：** 该文件唯一职责就是 iCloud KV 同步，没有复用价值；保留死代码会增加维护成本。未来恢复时从 Git 历史或重新实现都可接受。

### 决策 2：移除 AppBackend.onRemoteChange

**选择：** 从 `AppBackend` 协议中移除 `onRemoteChange` 属性，同时移除 `PandaCoreBackend` 与 `AppModel` 中的相关接线。

**理由：** 远端变更回调是 iCloud 同步的专属产物；本地文件变更由保存操作直接刷新 UI，不需要回调。

### 决策 3：iOS 统一使用 Dev entitlements

**选择：** `PandaSSH-iOS` Debug/Release 均使用新建的 `PandaSSH-iOS-Dev.entitlements`（仅沙箱+网络）。未来加入付费账号后再创建 Release entitlements。

**理由：** 当前阶段个人账号无法使用 App Groups，统一最小 entitlement 最省事；Release 构建在本期也走 Dev 配置，避免 CI 或个人打包时失败。

### 决策 4：macOS Dev/Release entitlement 保持不变但移除 iCloud/App Groups

**选择：** `PandaSSH-macOS-Dev.entitlements` 继续用于 Debug（仅沙箱+网络），`PandaSSH-macOS.entitlements` 也移除 iCloud/App Groups，用于 Release。

**理由：** macOS 没有 iOS 严格的沙盒要求，Release 仍需要网络 client；移除 iCloud/App Groups 后可使用 ad-hoc/self-signed 签名分发。

## Risks / Trade-offs

- **[配置不再跨设备同步]** → 可接受，当前个人账号本就构建不出 iOS 版本。
- **[恢复同步时的迁移]** → 本地 TOML 格式不变，恢复时只需重新接入 push/pull/监听逻辑。
- **[钥匙串仍同步]** → 保留 `kSecAttrSynchronizable`，用户若登录同一 iCloud 账号，密码/口令仍可能通过 iCloud Keychain 漫游，这是预期行为，不依赖 App Groups。
