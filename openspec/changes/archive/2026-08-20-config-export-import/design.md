## Context

当前配置仅落盘于本地文件（macOS `~/.panda-ssh/`，iPadOS App Group 容器）。iCloud 同步已移除，用户缺乏跨设备迁移配置的官方途径。见 proposal.md - Why。

## Goals / Non-Goals

**Goals:**
- 提供一键导出/导入配置的能力，覆盖主机、分组、代码片段与主机密钥信任记录。
- 导出文件格式自描述、可版本化，便于未来扩展。
- 导入时安全降级：不引入与 iCloud KV 冲突的同步机制。

**Non-Goals:**
- 不实现增量/差异同步。
- 不导出 SSH 会话状态、传输任务历史等临时数据。
- 不在 Rust core 中实现打包逻辑（本期仅在 Swift 侧实现）。

## Decisions

### 决策 1：`.pandassh` 文件格式为 ZIP

**选择：** 使用标准 ZIP 格式，内部固定目录结构。

**理由：**
- ZIP 为 macOS/iPadOS 原生支持（`Foundation` 的 `ZIPFoundation` 或 `FileManager` + `Compression`）。
- 可直接解压查看内容，便于调试。
- 未来可在 manifest 中声明压缩方式。

**目录结构：**
```
manifest.json
config/hosts.toml
config/groups.toml
config/known_hosts
snippets/
```

### 决策 2：导出/导入逻辑放在 Swift 侧

**选择：** 使用 Swift `FileManager` 与 `ZIPFoundation`（或原生 `Compression`）实现打包/解包。

**理由：**
- 配置目录路径在 Swift 侧已封装（`AppPaths`）。
- 涉及平台文件选择器（`NSOpenPanel` / `UIDocumentPickerViewController`），天然在 Swift 侧。
- 若未来 Linux GTK4 需要复用，可再下沉到 Rust core；当前保持最小侵入。

### 决策 3：导入策略为覆盖 + 自动备份

**选择：** 导入直接覆盖本地文件，旧文件自动备份为 `<filename>.backup.<timestamp>`。

**理由：**
- 全量导入语义简单，用户预期明确。
- 自动备份提供回滚可能，降低误操作风险。
- 不引入复杂的三向合并逻辑。

### 决策 4：manifest 版本号采用简单整数

**选择：** `manifest.json` 中 `"version": 1`。

**理由：**
- 与语义化版本解耦，仅表示文件格式迭代。
- 导入时直接比较整数，不匹配即拒绝。

## Risks / Trade-offs

- **[导出包泄露配置信息]** → 导出包不含明文密钥，但含主机地址与用户名。用户自行保管导出文件。
- **[导入后凭据缺失]** → 钥匙串不随导出包迁移，导入后首次连接需手动输入。在导入完成提示中明确说明。
- **[大 snippets 目录导致导出包过大]** → ZIP 压缩可缓解；未来若出现性能问题，可增加「选择导出内容」选项。
