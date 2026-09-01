# `PandaSSH.Config.ConfigImporter`

源文件：`apple/PandaSSH/Config/ConfigImporter.swift`

## 直接依赖

- `PandaSSH.Config.ConfigArchiveUtility`：读取 ZIP 条目与内容。
- `Foundation.FileManager`：备份、目录管理及落盘。
- `Foundation.JSONSerialization`：读取 `manifest.json`。
- `Foundation.Data`：以原子选项写入配置文件。

## 被依赖方

- `PandaSSH.SettingsView`：用户触发配置导入。
- `PandaSSHTests.ConfigExportImportTests`：导入行为验证。

## 边界

该实体负责导入事务和目标路径约束；不应把 ZIP 条目名直接当作本地相对路径，也不应吞掉备份、删除或写入失败。

