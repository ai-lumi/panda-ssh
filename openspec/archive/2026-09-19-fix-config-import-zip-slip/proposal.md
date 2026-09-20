## Why

当前配置导入会将归档中的条目名直接拼接到配置目录并写入。恶意 `.pandassh` 文件可利用父目录或绝对路径逃逸配置目录，在导入进程权限范围内写入或移动非预期文件；现有 manifest 与必需文件校验不足以阻止该行为。

## What Changes

- 将配置导入的归档路径约束为受支持的配置文件集合：根目录的 `hosts.toml`、`groups.toml`、可选 `known_hosts`，以及 `snippets/` 下的单层文件。
- 导入 SHALL 在任何备份、创建目录或写入发生前拒绝含绝对路径、父目录组件、空/目录条目、非允许层级或重复目标的归档；失败时不得改变配置目录外的文件。
- 将路径校验失败作为可识别的导入错误传递给现有 FFI/UI 错误处理，且不改变有效归档的导入结果、备份及非 ASCII snippet 文件名兼容性。
- 以 TDD 增加正常归档、恶意路径与边界归档的测试，并验证外部既有文件不会因备份逻辑被移动。

## Non-goals

- 不改变归档格式版本、导出范围、凭据排除规则或现有有效 `.pandassh` 文件的导入语义。
- 不在本次处理 ZIP 炸弹、压缩率/总大小限制、签名校验、恶意配置内容语义校验或归档来源可信度问题；这些是独立的资源控制与完整性议题。
- 不在 Swift 实现第二套归档路径校验；业务安全边界保持在跨平台的 Rust core。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `config-export-import`：配置导入增加归档条目路径与允许文件集合校验，并定义拒绝不安全归档时的无副作用行为。

## Impact

- Rust：修改 `crates/panda-core/src/config_archive.rs` 的导入验证和错误类型，新增/扩展同模块单元测试；不新增依赖。
- FFI：沿用同步 `config_import(archive_path)` 和既有错误映射，仅透传新增的安全导入错误，不改变导出函数或运行时模型。
- macOS 与 iPadOS：共享的导入调用路径继续展示导入失败；无需平台分支或界面行为改动。
- 规格：更新 `config-export-import` 的导入校验契约。实现完成并验证后才合并 delta 与归档本变更。
