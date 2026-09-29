# config-archive Specification

## Purpose

配置导入导出能力：用户可将全部配置（主机、分组、known_hosts、代码片段）打包为 `.pandassh` 归档文件用于备份或迁移到其他设备，也可从归档文件恢复配置。

## Requirements

### Requirement: 配置导出

系统 SHALL 通过 FFI 暴露 `config_export(output_path)` 接口，将配置目录中的 `hosts.toml`、`groups.toml`、`known_hosts` 和 `snippets/` 下全部文件打包为 ZIP 归档。归档 SHALL 包含 `manifest.json`，记录版本号（当前为 1）、导出时间戳（ISO 8601）和设备名称。设备名称 SHALL 通过跨平台方式获取（hostname）。

#### Scenario: 导出完整配置

- **GIVEN** 配置目录有 hosts.toml、groups.toml、known_hosts 和 3 个 snippet 文件
- **WHEN** 调用 `config_export("/tmp/backup.pandassh")`
- **THEN** 生成的 ZIP 包含 `manifest.json`、`hosts.toml`、`groups.toml`、`known_hosts`、`snippets/snippet-1.md`、`snippets/snippet-2.md`、`snippets/snippet-3.md`

#### Scenario: manifest 内容

- **WHEN** 检查导出归档中的 `manifest.json`
- **THEN** 包含 `{"version": 1, "timestamp": "2026-09-09T...", "device_name": "..."}`

#### Scenario: 空配置导出

- **GIVEN** 配置目录只有空的 hosts.toml 和 groups.toml
- **WHEN** 调用 `config_export()`
- **THEN** 成功生成归档，包含空配置文件和 manifest

### Requirement: 配置导入

系统 SHALL 通过 FFI 暴露 `config_import(archive_path)` 接口，从 `.pandassh` 归档恢复配置。导入前 SHALL 对已有配置文件进行带时间戳的备份。导入 SHALL 校验归档结构：必须包含 `manifest.json`、`hosts.toml`、`groups.toml`。版本不匹配 SHALL 返回错误。导入 SHALL 恢复 snippets 目录内容。

#### Scenario: 正常导入

- **GIVEN** 一个有效的 `.pandassh` 归档
- **WHEN** 调用 `config_import("/tmp/backup.pandassh")`
- **THEN** 配置恢复，返回备份文件列表和导入统计

#### Scenario: 预导入备份

- **GIVEN** 配置目录已有 hosts.toml
- **WHEN** 调用 `config_import()`
- **THEN** 旧 hosts.toml 被备份为 `hosts.toml.bak.<timestamp>`

#### Scenario: 版本不匹配

- **GIVEN** 归档 manifest 版本为 99
- **WHEN** 调用 `config_import()`
- **THEN** 返回错误 `VersionMismatch`

#### Scenario: 缺少必需文件

- **GIVEN** 归档缺少 `hosts.toml`
- **WHEN** 调用 `config_import()`
- **THEN** 返回错误 `MissingRequiredFile`

#### Scenario: 非 ASCII 文件名

- **GIVEN** snippets 中包含中文文件名 `笔记.md`
- **WHEN** 导出后导入
- **THEN** 文件名完整保留，内容一致
