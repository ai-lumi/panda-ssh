# Proposal: 移除 iCloud 配置同步功能

## Summary

暂时移除 macOS / iPadOS 间的 iCloud Key-Value Storage 配置同步能力，以及 Settings 页中的 iCloud 同步开关。钥匙串仍允许 iCloud Keychain 漫游，但配置文件的跨设备同步改为下一版本预留，待加入 Apple Developer Program 后再启用。

## Motivation

当前 iOS 构建需要 iCloud KV + App Groups entitlement，而个人开发者账号（Personal Team）不支持这些能力，导致 Xcode 无法创建 iOS App Development provisioning profile，iOS 真机/模拟器调试被阻断。为让本地开发构建在个人账号下可运行，本期先移除 iCloud 配置同步相关代码与配置，把该能力标记为后续版本功能。

## Changes

- **移除** `apple/PandaSSH/Sync/ConfigSync.swift` 中的 iCloud KV 同步逻辑：`ConfigSnapshot`、`ConfigKVStore`、`UbiquitousConfigKVStore`、`HostTOMLMerger`、`ConfigSync` 全部删除。
- **移除** `apple/PandaSSH/PandaCoreBackend.swift` 中对 `ConfigSync` 的启动拉取、变更监听与保存后 push 调用。
- **移除** `AppBackend.onRemoteChange` 回调（不再有远端配置变更）。
- **移除** `AppModel.iCloudSyncEnabled` 与 `SettingsView` 中的 iCloud 同步开关。
- **移除** `PandaCoreBridge.start()` 注释中关于 iCloud KV sync 的描述；保留 App Group 容器作为 iPadOS 本地存储路径。
- **移除** macOS / iOS entitlements 中的 `com.apple.developer.ubiquity-kvstore-identifier` 与 `com.apple.security.application-groups`。
- **修改** `apple/project.yml`：iOS Debug 使用不含 iCloud/App Groups 的 Dev entitlements；Release 暂同 Debug（直到付费账号就绪）。
- **修改** `openspec/specs/config-sync/spec.md`：将 iCloud KV 同步需求整体标记为 REMOVED，并说明下一版本恢复。
- **修改** `openspec/specs/auth/spec.md`、`host-config/spec.md`、`runtime-logging/spec.md` 中涉及 iCloud 同步的文案，改为「钥匙串本地存储」或下一版本预留。
- **修改** `README.md`、`CONTRIBUTING.md`、`AGENTS.md`、`openspec/config.yaml` 中关于 iCloud 配置同步的描述。

## Capabilities

### Modified Capabilities

- `config-sync`：移除 iCloud KV 配置同步，保留本地文件落盘；跨设备同步改为未来版本能力。

## Impact

- `apple/PandaSSH/Sync/ConfigSync.swift` — 删除
- `apple/PandaSSH/PandaCoreBackend.swift` — 移除 ConfigSync 调用
- `apple/PandaSSH/Mock/AppBackend.swift` — 移除 `onRemoteChange` 与 iCloud 文案
- `apple/PandaSSH/PandaSSHApp.swift` — 移除 `iCloudSyncEnabled`
- `apple/PandaSSH/SettingsView.swift` — 移除 iCloud 同步 Section
- `apple/PandaSSH/PandaCoreBridge.swift` — 更新注释
- `apple/PandaSSH/PandaSSH-iOS.entitlements` / `PandaSSH-macOS.entitlements` — 移除 iCloud/App Groups
- `apple/PandaSSH/PandaSSH-iOS-Dev.entitlements` / `PandaSSH-macOS-Dev.entitlements` — 新建/更新
- `apple/project.yml` — iOS 使用 Dev entitlements
- `openspec/specs/config-sync/spec.md` 等 — 同步文案

## Non-goals

- 本期不移除系统钥匙串同步属性（`kSecAttrSynchronizable`），密码/口令仍允许 iCloud Keychain 漫游。
- 本期不替代 iCloud 同步为其他同步方案（如 WebDAV、Git）。
- 本期不改变 macOS 使用 `~/.panda-ssh/`、iPadOS 使用 App Group 容器的本地落盘路径。

## Risks

- 移除后两端配置不再自动同步，但当前个人账号本来就无法构建 iOS 版本，此风险可接受。
- 未来恢复 iCloud 同步时需要重新设计并测试迁移路径。
