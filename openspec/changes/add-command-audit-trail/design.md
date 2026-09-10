# 设计：命令审计跟踪（add-command-audit-trail）

## Context

- 当前执行路径：`crates/panda-core/src/ssh.rs` 的 `SshSession::exec` / `exec_with_timeout`（60 秒默认超时，`Error::Timeout`；`ExecOutput.exit_status: Option<u32>`，服务器未报告时为 `None`）；SFTP 变更操作经 `crates/panda-ffi` 的同步导出（`sftp_upload`、`sftp_remove_file` 等）落到 panda-core。这是审计记录点的落位。
- 现有 `logger.rs` 是环形缓冲 + 100MB 单文件轮转的文本日志，写失败被静默忽略（`if file.write_all(...).is_ok()`），无序号、无完整性——只适合排查展示，不承担审计职责（runtime-logging 规格不变）。
- FFI 约定：所有导出同步，异步在懒初始化全局 tokio runtime 上 `block_on`；`init_store(config_dir)` 首次注入 store 根；密钥材料不经 FFI 落盘，凭据按「凭据引用（*_ref）+ 连接层按授权使用」处理。
- 存储环境：macOS `~/.panda-ssh/`、iPadOS App Group 容器，均经 `init_store` 注入；本地文件可被持有设备者读取与替换（本地可信边界，见路线图 4.4 [边界]）。
- 跨提案契约：执行计划/授权引用、九态执行状态机、审计缺段、阻断语义由四个并行提案共用；命令审计存储与巡检数据职责分开（路线图 8.7 决策 2），不要求同库。

## Goals / Non-Goals

**Goals:**

- 为 exec 与变更类 SFTP 操作提供先于提交的「尝试记录」与随后的「终态记录」两段式审计，使写入中断天然表现为结果未知。
- 存储与核验机制支持：序号连续性检查、段内/段间完整性检测、清理留痕、崩溃恢复（写入中断可见）、轮转/备份。
- 定义可被批量执行/巡检提案消费的阻断闸门契约（core 内统一入口）。
- 脱敏后的命令文本进审计，秘密材料不进任何审计负载。

**Non-Goals:**

- 交互 shell 命令记录、shell integration 信号解析、终端录像（后续阶段）。
- 对抗本机管理员的防篡改保证（只提供可检测条件与「不可验证」状态）。
- 修改 runtime-logging 行为；授权决策与审批状态机（属 add-execution-plan-authorization）。
- 定时任务（不在本批范围）。

## Decisions

### 决策 1：存储选型——追加式 JSONL 分段文件 + 段清单（弃 SQLite）

**选择**：审计目录（`<store根>/audit/`）下按段存文件：`segments/seg-000001.jsonl` 追加写 JSON Lines，每条一行一条记录；每段封存时写清单 `segments/seg-000001.manifest.json`（首/末序号、记录数、段内链式摘要、前段清单摘要）。另有 `state.json`（下一序号、当前段号、阻断状态）。

**对照 SQLite（rusqlite）的取舍**：

| 关注点 | JSONL 分段 + 清单 | SQLite |
|---|---|---|
| 连续性校验 | 逐行序号检查，段清单给边界锚点，直观可增量 | rowid 自增但外部 UPDATE/DELETE 不留痕，需额外事件表 |
| 删除留痕 | append-only 追加清理留痕行，天然契合 | DELETE 后「被删」与「从未写入」不可区分，留痕需再建一层日志 |
| 崩溃恢复 | 残缺尾行（无换行/解析失败）可检测 → 明确的「写入中断」证据 | 事务回滚恢复后中断不可见——恰与审计需求相反 |
| 轮转/备份 | 段即归档单位，按段备份/校验 | 需快照导出，单文件整体替换更难定位缺段 |
| 点查询 | 弱，需扫描（段清单常驻内存可跳段，审计场景以顺序浏览/范围过滤为主，可接受） | 强 |
| 依赖/体积 | 零新增（serde_json、sha2 已在依赖中） | 新增 rusqlite，FFI 体积与跨平台编译负担 |

审计的核心诉求是「追加不可变 + 中断可见 + 留痕可追加」，SQLite 的事务原子性反而抹掉写入中断的证据；故选 JSONL。查询性能以「段元数据常驻内存 + 按段跳读 + 单写者 Mutex（沿用 logger 模式，FFI 同步 block_on 下天然串行）」缓解。

**不选**：复用 runtime-logging 单文件轮转日志（无序号/完整性、轮转覆盖备份会无声毁证据、写失败静默）。

### 决策 2：两段式记录模型（Attempt → Outcome）

`AuditRecord` 为 serde tagged 枚举：`CommandAttempt` / `CommandOutcome` / `SftpAttempt` / `SftpOutcome` / `Clearance`（清理留痕）/ `Recovery`（恢复记录）。字段：

- 共同：`seq: u64`（全局单调，由存储层写入时分配）、`timestamp`、`kind`。
- `CommandAttempt`：`attempt_id`（uuid）、命令文本（脱敏后 + `redacted: bool` + 脱敏区间描述）、目标主机标识、执行主体、计划引用 `Option<PlanRef{ plan_id, content_version }>`（`content_version` 即 add-execution-plan-authorization 的计划内容哈希 `content_hash`）、凭据引用标识（仅 `*_ref`）。
- `CommandOutcome`：`attempt_id`、结果状态（成功/失败/超时/取消请求/已确认停止/结果未知/被拒绝）、`exit_status: Option<u32>`（仅服务器报告时非空；缺退出码 MUST NOT 填零）、`remote_state_known: bool`（已提交未收退出码时为 false）、验证证据引用（stdout/stderr 字节长度 + 内容 SHA-256 摘要——哈希不可逆，不泄内容）、失败摘要（非敏感）。
- `SftpAttempt`/`SftpOutcome`：目标路径、操作类别（上传/下载/删除文件/删除目录/创建目录）、数据流向、`Option<冲突决策>`、终态、（传输类）字节计数。不记录文件正文。
- 命令提交前 MUST 成功写入 Attempt（写失败 → 不提交 → 闸门阻断）；结束补写 Outcome；两者之间崩溃/中断 → 只有 Attempt → 展示为结果未知 + Recovery 记录说明。这一结构直接落实「写入中断后已发出操作保留未知状态」。

替代方案（单记录原地更新）被否：append-only 下无法更新，且更新语义会破坏篡改可检测性。

### 决策 3：完整性机制——段内链式摘要 + 段间清单链，显式声明边界

- 段内：每条记录计算 SHA-256 摘要，第 n 条摘要输入包含第 n−1 条摘要（段内哈希链）；清单存段首/末序号、记录数、段摘要。检测：段内修改、重排、删除、插入。
- 段间：每段清单含前段清单摘要（清单链）；检测：段缺失、段重排、尾部截断（末段记录数与清单/状态不符）。
- 结果三态：`Verified`（核验通过）/ `Compromised(定位)`（可检出损坏）/ `Unverifiable`（无法核验，如清单链断裂、旧副本回滚）。
- 边界声明（写入 spec 与 UI）：整库替换、完整旧副本回滚无法凭本地材料无条件检出；「Unverifiable」按阻断契约处理，不静默通过。
- 不选全库 Merkle 树/签名：本地私钥可被同一操作者替换，签名只增加复杂度不改变可信边界；路线图 4.4 明确不承诺对抗本机管理员。

### 决策 4：阻断闸门（AuditGate）位于 panda-core 执行入口

- `AuditGate` 状态：`Open` / `Blocked(reason)`，状态持久化于 `audit/state.json`（崩溃/重启后仍阻断）。
- 执行入口统一前置检查：`exec` 与变更类 SFTP 提交前必须 `gate.check()` + Attempt 写入成功；审计写失败/存储耗尽/完整性 Unverifiable → 置 `Blocked`，后续系统代发步骤全部拒绝并返回可区分错误，Swift 呈现阻断原因。
- 恢复流程：用户触发 `recover` → 校验 + 补写 Recovery 记录（说明中断区间，已有 Attempt 标记结果未知）→ 核验通过 → `Open`。批量执行/巡检提案的步骤循环在同一闸门上消费此契约（每步前置检查），本提案只定义契约与 core 内实现。
- 与授权的关系：授权强制检查（add-execution-plan-authorization）与审计闸门在同一 Rust 执行入口串联；被授权拒绝的尝试也写入被拒终态记录。学习/AI/Skill/记忆无闸门操作权限（不得解除阻断、不得写/改审计）。

### 决策 5：脱敏——模式化启发式 + 显式标记

- 检测规则（core 内，跨平台一致）：口令/令牌赋值形态（`password=`、`token=`、`PASS` 环境变量赋值等）、OpenSSH 私钥块、长 base64/hex 连续串。命中片段以 `[已脱敏]` 占位，`redacted: true` + 脱敏片段计数/区间入记录。
- 原文不留任何副本（内存替换后即弃）；无命中则原文保真 + `redacted: false`。
- 明示局限：启发式不能保证检出全部秘密（spec 已声明）；输出（stdout/stderr）不落审计正文，只落长度 + SHA-256 摘要作证据引用，天然规避输出泄密。

### 决策 6：轮转与保留——段封存不覆盖，超限走授权清理

- 段达阈值（默认 10MB 或 10000 条，可调）即封存写清单、开新段；封存段永不原地改写或删除。
- 存储预算超限时不自动静默删段（会制造「异常缺失」误报），而是置入「建议清理」提示，由用户执行清理——清理经 `Clearance` 留痕路径，表现为授权清理缺段。
- 备份 = 用户按段复制文件；清单链跨段衔接使「用旧段替换新段」表现为链断裂 → Unverifiable（诚实呈现边界）。

### 决策 7：FFI 与 Swift 面

- panda-ffi 新增同步导出（简单值类型 Record/Enum，`runtime().block_on`）：`audit_query(range)`（分页读记录与缺段标注）、`audit_integrity_report()`、`audit_clear(start, end, reason)`、`audit_recover()`。密钥材料不涉及。
- `AppBackend` 协议新增对应方法；`MockBackend` 提供内存实现（供 Preview 与单元测试）；`AuditHistoryView` 双端共享 SwiftUI：记录列表（按执行主体/结果状态过滤）、缺段条带（四类原因着色）、完整性状态横幅、清理与恢复入口。macOS 以窗口/标签承载，iPadOS 以侧栏入口承载——仅导航容器差异，无业务 `#if os()`。

## Risks / Trade-offs

- [JSONL 顺序扫描随历史变慢] → 段清单常驻内存按段跳过；范围查询限定段区间；必要时（后续阶段）加段内稀疏索引，不改格式。
- [脱敏启发式漏检秘密] → 局限已声明；输出只存摘要；用户可对高危命令先自行脱敏；阶段二可引入按主机规则，规格不变。
- [Attempt 与 Outcome 之间的崩溃造成未知态] → 这正是需求语义；Recovery 记录 + 结果未知展示；不自动补全。
- [序号分配与写入失败窗口] → 序号由存储层在成功追加时分配（写入失败不占号）；中断造成的空洞由 Recovery/Clearance 或「证据不足/异常缺失」分类如实呈现。
- [多入口并发写] → 单写者 Mutex + 全局 runtime block_on 串行化；并发测试覆盖序号连续。
- [审计存储放大本地存储占用] → 段阈值 + 超限清理提示；清理留痕体积远小于原记录。
- [iPadOS 容器空间紧张] → 存储耗尽即阻断并提示（宁可阻断不可无声丢审计），引导用户清理/导出后清理。

## Migration Plan

1. 新增 `panda-core::audit` 模块与存储目录（`init_store` 时创建 `audit/segments/`、`state.json`），无存量数据迁移（首个审计版本）。
2. exec 与 SFTP 执行路径接入记录点与闸门；旧版本产生的无审计执行行为不追溯补记。
3. FFI 与 Swift 面随后接入；回滚 = 移除模块与 UI（无数据兼容负担，审计目录保留不影响旧版本运行）。

## Open Questions

- 段阈值（10MB/10000 条）与查询分页大小的默认值：留实现期基准调优，不影响规格与任务拆分。
- 审计记录的展示排序/过滤组合的最终 UI 形态：属实现细节，评审时按双端导航定稿。
- `Clearance` 留痕是否需要独立的操作确认二次弹框（macOS/iPadOS 交互差异）：实现期定，不影响契约。
