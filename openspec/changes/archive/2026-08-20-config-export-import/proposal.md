## Why

当前 iCloud 配置同步已移除，用户跨设备迁移主机配置、分组与代码片段缺乏官方途径。需要一种不依赖 Apple 开发者账号与云端服务的替代方案，让用户能够自主导出完整配置包并在其他设备导入。

## What Changes

- 新增「配置导出」功能：将 hosts.toml、groups.toml、known_hosts、snippets 目录打包为单个 `.pandassh` 文件（ZIP 格式），支持可选包含/排除密钥材料引用。
- 新增「配置导入」功能：读取 `.pandassh` 文件，校验格式版本，合并或覆盖本地配置；冲突时以导入为准并备份旧文件。
- Settings 页新增导出/导入入口。
- 导出时 SHALL NOT 包含明文密码或私钥口令，仅导出钥匙串引用 key；导入后凭据需重新录入或依赖钥匙串漫游。

## Non-goals

- 本期不实现增量/差异同步，仅支持全量导出/导入。
- 不替代未来 iCloud 同步；导出/导入作为无云端能力时的降级方案保留。
- 不导出 SSH 会话历史、传输任务记录等临时状态。

## Capabilities

### New Capabilities
- `config-export-import`: 配置导出与导入的文件打包、校验、合并逻辑，以及 UI 入口。

### Modified Capabilities
- `config-sync`: 在「本地存储位置」或「跨设备同步预留」中补充说明：导出/导入为当前无 iCloud 时的跨设备迁移方式。

## Impact

- SwiftUI：SettingsView 新增导出/导入按钮；macOS 使用 `NSSavePanel`/`NSOpenPanel`，iPadOS 使用 `UIDocumentPickerViewController`。
- Rust core（可选）：若导出/导入逻辑需要跨平台复用（Linux GTK4 后期），可在 `panda-core` 实现打包/解包/校验；本期先在 Swift 侧实现，保持最小侵入。
- 文件格式：`.pandassh` 为 ZIP，内部固定目录结构，含 `manifest.json`（版本、导出时间、设备标识）。
