# Panda SSH Specs 三方评审报告

- **日期**：2026-08-04
- **评审对象**：`openspec/specs/` 全部 6 个 spec（host-config、host-key-verification、ssh-connection、sftp-transfer、ffi-bridge、config-sync）
- **评审方式**：产品专家 / 架构师 / 程序员三个独立视角并行评审，全部对照 `crates/` 与 `apple/` 实际代码核实；评审为只读，未修改 spec 与代码
- **评审时背景**：骨架初始化刚完成（cargo test 9 绿、macOS/iOS 模拟器编译通过），`openspec/changes/` 下已有 8 个未归档变更提案

## 一、总体结论

骨架期 specs 质量**高于同类早期项目**：模块边界与 crate 结构一一对应，凭据边界（钥匙串 vs TOML 引用）在三个 spec 中表述一致且代码落实；host-config、host-key-verification 与代码吻合度最高且有测试支撑。未发现大面积「spec 写了但代码不是那样」的失真。

但存在三类系统性问题，需要在进入联调阶段前处理：

1. **安全语义被骨架实现反向合法化**：静默 TOFU（`AcceptAndStore`）写进了 spec 却没有发布门禁；FFI flat error 把错误分类抹平成字符串，UI 无法区分「密码错 / 网络不通 / 密钥变了」。
2. **跨 spec 断链与矛盾**：SFTP 删除/建目录能力在 FFI 边界被截断；上传进度回调到不了 Swift；config-sync 的 Purpose 与 Requirement 自相矛盾，且其核心行为在代码里尚未接线（死代码）。
3. **TDD 红线在 ssh/sftp 两个能力上实际停摆**：这两个 spec 的全部 Scenario 依赖真实 SSH 服务器，当前 0 测试、spec 未给测试策略。

另有两处**正确性缺陷**必须修复：钥匙串访问组缺少 Team ID 前缀（真机凭据读写必失败）；known_hosts 一机多 keytype 会误报 Mismatch（假 MITM 且密钥永远无法更新）。

## 二、问题清单（按严重级，已去重合并三方意见）

### 阻断（联调/发布前必须解决）

| # | 问题 | 位置 | 提出方 |
|---|------|------|--------|
| B1 | **钥匙串访问组规格化了错误值**：spec 与 `KeychainHelper.swift` 写死 `com.pandassh.shared`，entitlements 声明的是 `$(AppIdentifierPrefix)com.pandassh.shared`；真机 `SecItemAdd` 必返回 errSecMissingEntitlement。macOS Dev 构建 entitlements 无 keychain-access-groups，且 `HostEditView` 忽略 `save` 返回值——密码静默丢失、ref 已写进 TOML | config-sync spec / KeychainHelper / HostEditView | 架构师、程序员 |
| B2 | **known_hosts 多 keytype 误报 Mismatch**：`check()` 遇到第一个 host 匹配行即返回，真实服务器常有 ed25519+ecdsa+rsa 多把 host key；且无任何删除/替换 API，密钥永远无法更新，TOFU 确认 UI 缺前置路径 | host-key-verification spec / hostkey.rs | 架构师、产品 |
| B3 | **静默 TOFU 被 spec 合法化且无发布门禁**；且 `Reject` 策略的 `UnknownHostKey` 错误只带 host:port、不携带服务端呈现的密钥指纹，spec 承诺的「UI 自行提示确认」在当前错误类型下无法实现 | host-key-verification / ffi-bridge / ssh.rs | 产品、程序员 |
| B4 | **跨 spec 矛盾：远程文件管理到不了 UI**——sftp-transfer 要求删除文件/目录/建目录，ffi-bridge 导出清单无对应函数，FFI 确实未导出 | sftp-transfer vs ffi-bridge | 程序员、产品 |
| B5 | **config-sync 核心行为是死代码**：`ConfigSync.shared` 全工程无调用方，保存后无人 push、启动无人 pull；spec 写的是系统行为但无代码路径触发 | config-sync spec / ConfigSync.swift | 程序员 |
| B6 | **FFI flat error 抹平错误分类**：`AuthFailed`/`Timeout`/`HostKeyMismatch` 全部压成 `PandaError::Core(String)`，UI 无法做针对性引导（如密钥变更给「更新指纹」入口） | ffi-bridge spec / panda-ffi | 产品、程序员、架构师 |

### 重要

| # | 问题 | 提出方 |
|---|------|--------|
| I1 | 首启/空配置行为未规格化（代码已实现 missing file → 空列表，有测试，spec 无条目） | 产品 |
| I2 | **私钥跨设备暗坑**：`key_path` 是本地绝对路径会随配置同步，但私钥文件不漫游——Mac 配的密钥登录同步到 iPad 必然认证失败，无任何 spec 规定用户看到什么 | 产品 |
| I3 | **known_hosts 是否随配置同步无决策**：双端信任状态分裂，一端被 MITM 接受错误密钥另一端无从知晓 | 产品、架构师 |
| I4 | **上传进度回调断在 FFI 边界**：core 有进度参数，FFI 硬传 `None`；下载无进度要求（上传/下载不对称） | 架构师、程序员、产品 |
| I5 | **钥匙串 ref 生命周期缺失**：删除主机不级联清理钥匙串条目（`KeychainHelper.delete` 无人调用），孤儿密钥随 iCloud 漫游 | 架构师、产品 |
| I6 | 会话生命周期未规格化：`disconnect` 无 Requirement；`exec()` 无超时（命令挂死则调用线程永久阻塞）；三个 30 秒超时揉在一条 Requirement 里 | 产品、架构师 |
| I7 | **同步 block_on 无线程约束**：AppModel 是 `@MainActor`，连接类接口从 UI 事件直接调用将阻塞主线程最长 30 秒；「从任意线程调用不 panic」的承诺过强（tokio 线程内 block_on 必 panic） | 架构师 |
| I8 | **ssh/sftp 测试策略缺失**：两 spec 全部 Scenario 依赖真实服务器，0 覆盖；可行路径是 russh server API 起进程内 fake server 做集成测试，spec/change 未写明 | 架构师、程序员 |
| I9 | config-sync spec 自相矛盾：Purpose 称监听属后续变更，Requirement 却已规格化 `startObserving`；对冲突合并、KV 1MB 上限、iCloud 未登录行为完全沉默 | 架构师、产品 |
| I10 | `init_store` 进程级 `OnceLock`：不可重入导致「未初始化调用」Scenario 不可测、panda-ffi 写不了单测；语义应限定「进程内首次生效」 | 程序员、架构师、产品 |

### 建议

- S1. keyboard-interactive 认证不支持应记录为 Non-Goal（很多服务器默认开启，否则用户当 bug 报）— 产品/程序员
- S2. 明确「每主机单密钥」或按 `(host, keytype)` 多记录（随 B2 一并解决）— 产品
- S3. known_hosts 裸 `fs::write` 非原子，与 host-config 的原子写标准不一致 — 架构师/程序员
- S4. 「不出现任何密码明文」不可判定，建议改为「不出现 password/passphrase 字段、仅出现 `*_ref`」；补「TOML 损坏报错」「同 id upsert 为替换」负向 Scenario — 程序员
- S5. 上传完成时 MUST 以 `sent == total` 收尾回调（空文件当前零回调）；补 SFTP 负向场景（目录不存在、权限不足、删除非空目录）— 程序员
- S6. UI 相关 Scenario 用用户语言书写（config-sync 是好例子）；core 类可保留测试语言 — 产品
- S7. 输入校验责任划分不明：空 host、端口 0、非法端口（`UInt16(port) ?? 22` 静默吞错）在哪层拒绝 — 产品/架构师
- S8. 「每次调用新建连接 / 不做连接池」应标注为骨架期临时约束，避免被当成架构定稿 — 架构师
- S9. Swift 侧自生成 UUID 与 FFI「空 id 生成 UUID」双路径，二选一 — 架构师
- S10. `SshSession::connect` 的 `&mut KnownHosts` 参数从未被使用（内部按 path 重建），接口误导 — 程序员
- S11. spec 补 Non-Goals（端口转发、私钥生成、导入导出、known_hosts 手动编辑），把「极简」边界写成决策 — 产品
- S12. 「Swift 绑定可生成」Scenario 注明为手动/CI 验证步骤；xcframework 为 arm64-only 应写明 — 程序员
- S13. 流程：6 个 spec 无归档变更记录、8 个活跃提案与 specs 并存，追溯链断——建议补归档动作 — 产品
- S14. host-key 相关错误预留结构化 Record 暴露（指纹对比），为 TOFU UI 演进留口 — 架构师

## 三、分 spec 结论

- **host-config**：最扎实的一份，模型/原子写/路径注入均规格化且有测试（9 个单测中 5 个覆盖）。补：空文件行为（I1）、校验规则（S7）、并发约定、可判定措辞（S4）。
- **host-key-verification**：三态判定与双策略写得清楚、质量最高之一；但 B2（多 keytype 正确性缺陷）、B3（TOFU 门禁 + Reject 信息不足）、I3、S3 都集中在这里，联调前必须修。
- **ssh-connection**：范围克制（明确不做交互式 shell）值得肯定；缺 exec 超时、测试策略（I8）、keyboard-interactive Non-Goal；空闲 30 秒对未来终端场景偏激进，tabbed-workspace 落地时重新审视。
- **sftp-transfer**：core 实现完整且与 spec 对齐；但 B4（管理功能未过 FFI）、I4（进度断链）、负向路径全缺（S5）。
- **ffi-bridge**：导出清单/同步语义/初始化/凭据边界与代码逐条吻合，写得最准；问题都在接缝上——B6（flat error）、I7（线程约束）、I10（OnceLock）、I4。是全项目风险最高的一层，值得一份专门 design 补强。
- **config-sync**：方向正确（密钥不过 KV、容器回退是好决策）但问题最多：B1（访问组）、B5（未接线）、I9（自相矛盾）、I5（ref 生命周期）、I2（私钥跨设备）。

## 四、建议的后续变更提案（按优先级归并三方建议）

1. **`fix-keychain-access-group`**（B1）：访问组改为带 App ID Prefix 的完整值，spec 与代码同步；钥匙串写入失败 MUST 显式报错阻止保存；补 KeychainHelper XCTest。
2. **`known-hosts-multi-key`**（B2 + S3）：按 `(host, keytype)` 存取、支持删除/替换、原子写入；为 TOFU 确认 UI 铺路。
3. **`host-key-tofu-prompt`**（B3）：`UnknownHostKey` 携带 presented 密钥与指纹；FFI 暴露 Reject 策略；host-key-verification spec 加「AcceptAndStore 仅开发期过渡，首个发布版本 MUST 切换为确认式」的门禁文字。与现有 `server-management` 提案合并推进并提为发布必需。
4. **`error-surfacing`**（B6 + S14）：core 错误分类 → FFI 结构化错误（uniffi enum）→ UI 可区分提示。横跨三个 spec，建议独立提案。
5. **`ffi-sftp-management` + `ffi-upload-progress`**（B4 + I4）：补齐删除/建目录导出；用 uniffi callback interface 暴露传输进度（或明确随 transfer-tasks 变更落地，消除规格断链）。
6. **`config-sync-wiring`**（B5 + I5 + I9 + I2）：保存/删除后自动 push、启动 pull + 监听、KV store 抽象为可注入协议、known_hosts 同步决策、钥匙串 ref 级联清理、私钥跨设备缺失的检测与引导。
7. **`ssh-integration-test-harness`**（I8）：基于 russh server API 的进程内 fake SSH/SFTP 服务器测试基架，兑现 TDD 红线。
8. **`ffi-async-calling-convention`**（I7 + I6 + I10）：明确调用线程约束或迁移 uniffi async 导出；exec 超时；stores 可注入；标注连接池限制的临时性。
9. **（流程）归档骨架期变更记录**（S13），修复 specs 追溯链。
10. **（文档级，可不开提案）**：各 spec 补 Non-Goals（S1、S11）；Scenario 措辞可判定化（S4、S6）。

## 五、附注

- 评审中发现 `openspec/changes/` 下 8 个活跃提案（server-groups、server-management、authentication、tabbed-workspace、transfer-tasks、code-snippets、config-sync、cross-platform-foundation）覆盖了多数「缺失能力」类意见，本报告不再把已有提案的内容计为「缺失」。
- 个别评审细节经核实不予采纳（如「AGENTS.md 称 uniffi-bindgen bin 不存在」与实际不符）。
