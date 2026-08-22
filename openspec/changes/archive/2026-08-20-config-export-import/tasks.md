## 1. 测试任务

- [x] 1.1 编写导出打包测试：验证 ZIP 内包含 hosts.toml、groups.toml、known_hosts、snippets 与 manifest.json；验证 hosts.toml 中不含明文密码。
- [x] 1.2 编写导入校验测试：验证版本不匹配时返回错误；验证 ZIP 损坏/缺失必要文件时返回错误；验证合法文件导入后本地配置被覆盖且旧文件已备份。
- [x] 1.3 编写导出/导入边界测试：验证空配置导出仍能生成有效包；验证 snippets 目录为空时导出正常；验证导入后 `password_ref` 存在但钥匙串缺失时的降级行为。

## 2. 核心实现

- [x] 2.1 实现 `ConfigExporter`（Swift）：收集 `AppPaths` 下全部配置路径，打包为 ZIP 并写入 `.pandassh`，含 `manifest.json`（version=1）。
- [x] 2.2 实现 `ConfigImporter`（Swift）：读取 ZIP，校验 manifest 版本，校验必要文件存在；覆盖前自动备份旧文件到 `<filename>.backup.<timestamp>`。
- [x] 2.3 在 `SettingsView` 新增导出/导入 Section：macOS 使用 `NSOpenPanel`/`NSSavePanel`，iPadOS 使用 `UIDocumentPickerViewController`；导入完成后调用 `AppModel.reload()` 刷新列表。

## 3. 集成与验证

- [x] 3.1 验证导出文件可在 Finder 中解压并查看内容，manifest.json 格式正确。
- [x] 3.2 验证导入后主机列表、分组、代码片段与导出源一致；验证旧文件备份存在。
- [x] 3.3 验证 `xcodebuild` macOS/iOS 双端编译通过（新增 Config 目录与 SettingsView 文件无编译错误）；验证 `openspec validate config-export-import --strict` 通过。
