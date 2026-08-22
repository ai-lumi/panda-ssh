## 1. 代码移除

- [x] 删除 `apple/PandaSSH/Sync/ConfigSync.swift`
- [x] 从 `apple/PandaSSH/PandaCoreBackend.swift` 移除 `ConfigSync` 启动 pull、监听、`pushConfig()` 调用
- [x] 从 `apple/PandaSSH/Mock/AppBackend.swift` 移除 `onRemoteChange` 属性与 iCloud 文案
- [x] 从 `apple/PandaSSH/PandaSSHApp.swift` 移除 `AppModel.iCloudSyncEnabled`
- [x] 从 `apple/PandaSSH/SettingsView.swift` 移除 iCloud 同步 Section
- [x] 更新 `apple/PandaSSH/PandaCoreBridge.swift` 注释，移除 iCloud KV sync 描述
- [x] 更新 `apple/PandaSSH/PreviewSupport.swift` / `MockBackend.swift` 等文件中的 iCloud 相关注释
- [x] 删除 `apple/PandaSSHTests/ConfigSyncTests.swift`
- [x] 从 `apple/PandaSSHTests/PreconnectGateTests.swift` 移除 `onRemoteChange`

## 2. 工程配置与签名

- [x] 移除 `apple/PandaSSH/PandaSSH-iOS.entitlements` 中的 `ubiquity-kvstore-identifier` 与 `application-groups`
- [x] 移除 `apple/PandaSSH/PandaSSH-macOS.entitlements` 中的 `ubiquity-kvstore-identifier` 与 `application-groups`
- [x] 新建 `apple/PandaSSH/PandaSSH-iOS-Dev.entitlements`（仅沙箱 + 网络）
- [x] 修改 `apple/project.yml`：iOS target 使用 `PandaSSH-iOS-Dev.entitlements`
- [x] 重新运行 `cd apple && xcodegen`

## 3. 规格与文档更新

- [x] 修改 `openspec/specs/config-sync/spec.md`：移除 iCloud KV 同步，标记 REMOVED，新增跨设备同步预留
- [x] 修改 `openspec/specs/auth/spec.md`：将「iCloud 同步」改为「系统钥匙串」，不强制漫游
- [x] 修改 `openspec/specs/host-config/spec.md`：移除 iCloud 同步相关描述
- [x] 修改 `openspec/specs/runtime-logging/spec.md`：移除 iCloud 同步相关日志事件
- [x] 修改 `openspec/config.yaml`：移除 iCloud Key-Value Storage 描述
- [x] 修改 `README.md`：说明 iCloud 配置同步为下一版本功能
- [x] 修改 `CONTRIBUTING.md`：更新 Debug/Release entitlement 说明
- [x] 修改 `AGENTS.md`：更新项目上下文中关于 iCloud 的描述

## 4. 验证

- [x] `cargo test --workspace` 全绿
- [x] `cd apple && xcodegen` 成功
- [x] `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS build` 在个人账号下不再报 iCloud/App Groups provisioning 错误
- [x] `openspec validate remove-icloud-config-sync --strict` 通过
