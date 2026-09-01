# `PandaSSH.Config.ConfigArchiveUtility`

源文件：`apple/PandaSSH/Config/ConfigArchiveUtility.swift`

## 直接依赖

- `Foundation.Data`：ZIP 二进制的组装、切片和读取。
- `Foundation` 的字符串编码能力：ZIP 条目名 UTF-8 编解码。

## 被依赖方

- `PandaSSH.Config.ConfigExporter`：创建配置归档。
- `PandaSSH.Config.ConfigImporter`：枚举并提取导入归档的条目。
- `PandaSSHTests.ConfigExportImportTests`：归档格式验证。

## 边界

该实体是归档格式边界；它不应承担导入目标路径策略或 UI 错误呈现。所有来自归档的偏移、长度和条目名均应视为不可信输入。

