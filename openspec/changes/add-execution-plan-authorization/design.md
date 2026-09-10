# 设计：执行计划与授权生命周期

## Context

现状（见 proposal.md - Why）：代码中没有任何计划/授权概念；可复用的现有构件——`KnownHosts`（`crates/panda-core/src/hostkey.rs`，文件级 `status()` 与连接期三态 `check()`）、`CredentialStore`/`credential_resolve`（凭据引用解析）、`PandaError` 结构化错误、FFI 同步导出 + 全局 tokio runtime 约定、传输任务的「启动返回任务标识 + 状态查询」模式（`start_transfer`）。既有连接入口 `test_connection` / `shell_open` / `sftp_session_open` / 无状态 `sftp_*` 均带 `trust_on_first_use` 参数，是用户显式 UI 动作驱动的手动路径。约束：业务逻辑只落 panda-core；FFI 同步、简单值类型、密钥材料只作瞬态参数；凭据表述统一为「凭据引用（*_ref）+ 连接层按授权使用」（存储基线由 resolve-baseline-conflicts 消解，本设计不预设其结论）。

## Goals / Non-Goals

**Goals:**

- 计划与授权的持久化模型、内容冻结与版本哈希，全部在 panda-core 可单测（时钟、审计、执行器、主机密钥均可注入 fake）。
- 网关成为系统代发执行的唯一通道，且校验发生在任何 SSH 连接建立之前。
- 九态状态机作为共享词汇落在本提案，批量执行/巡检直接复用。

**Non-Goals:**

- 真实多主机命令执行器（add-batch-remote-execution 交付，实现本设计定义的 `PlanExecutor`）。
- 审计记录的真实存储与完整性机制（add-command-audit-trail 交付 `AuditSink` 实现；本设计只定义 trait 语义与阻断行为）。
- 计划存储向 SQLite 迁移（路线图 8.6 的结构化存储选型留给后续结构化结果提案）。
- 跳板链连接实现、TOFU 流程改动、定时调度。

## Decisions

### D1：计划存储采用配置目录 TOML 单文件 + 原子写，计划与运行记录分离

- `plans.toml` 保存计划定义、内容哈希与批准记录；`plan_runs.toml` 保存运行记录（九态与逐目标状态）。均走既有 `write_atomic` 模式（与 hosts.toml / groups.toml / credentials.toml 一致）。
- 理由：与仓库现有持久化风格一致、无需新依赖、可 diff 可审计；运行状态更新频繁，与计划定义分离避免重写放大。
- 备选：SQLite（更适合高频繁写，但引入新依赖与迁移成本，且路线图已把结构化存储选型单列后续提案）；每计划一个文件（目录管理复杂，收益不大）。TOML 方案在计划数量（人审核、量级为个位/十位数）下足够。
- 运行中间态（运行中、取消请求）持久化在每次迁移时更新写入：崩溃后重开仍能看到「运行中被中断」的记录，随后由恢复逻辑归为结果未知，而不是凭空消失。

### D2：版本标识 = 规范化序列化后的 SHA-256 内容哈希；引用采用「快照 + 哈希」双重冻结

- 计划结构体经 serde 序列化（键序确定：字段全用 `BTreeMap`/定序结构）后取 SHA-256 作为内容哈希；计划 `id` 为 UUID，`content_hash` 为版本标识。提交审核后计划定义不可变，任何编辑产生新计划（新 id/哈希）。
- 引用片段/方案：计划内保存引用对象的**内容快照**与**提交时内容哈希**（对片段 body 等内容字节求哈希，内容寻址，不需要给 Snippet 增加版本字段）。执行一律使用快照内容（「Skill 出现新版本不自动替换运行版本」）；执行前对**当前存储中的引用源**重算哈希与冻结哈希比对，不一致 → 拒绝并失效。
- 理由：仅存哈希可校验但无法在源被改/删后重放审核内容；仅存快照则「相同命令字符串掩盖引用变化」。快照 + 执行前比对同时满足 4.2 的两个要求。备选「执行时从存储重读最新内容」被否决：那会让执行对象偏离审核对象。
- 实际上由快照执行的内容与冻结哈希天然一致；执行前对源的重算比对是「授权仍有效」的判定条件（源变了 → 旧授权失效 → 须重新审核），与「快照未被篡改」的自校验（对快照重算哈希 = 冻结哈希）并行实现。

### D3：生命周期与批准消耗

- 计划状态：`Draft → PendingReview → Approved → Executing → Completed`，终态 `Invalidated / Revoked`。迁移规则集中在纯函数 `transition(plan_state, event) -> Result<plan_state>`，非法迁移返回错误（可穷举测试）。
- 批准记录：`{ plan_id, content_hash, approved_at, expires_at: Option }`，追加进 `plans.toml`。启动执行时网关校验「最新批准记录的 content_hash == 计划 content_hash 且未撤销未过期」。
- 一次性语义：运行进入终态即消耗批准；`Completed` 计划可再次批准（新批准记录、同哈希）后再执行；`Invalidated/Revoked` 不可再批准（撤销后用户须新建计划重新审核——不提供「忽略过时提示」的绕过路径）。
- 暂停 = 对活动运行发出取消请求，等待停止确认后运行落 `已确认停止`/各步骤如实记录；计划回到 `Approved` 但批准已消耗，恢复执行须重新批准。撤销 = 计划直接进 `Revoked`，运行收 `取消请求 → 已确认停止`（无法确认停止时按事实落 `结果未知`），未发出步骤不再发起。

### D4：网关 = 校验编排器 + 注入式执行器，校验先行于任何连接

- panda-core 新模块 `execution`（gateway、状态机、授权判定）与 `plans`（存储、冻结、哈希）。`ExecutionGateway::start(plan_id, material, ...)` 顺序执行：
  1. 计划存在且状态允许执行（`Approved`）；
  2. 最新批准记录哈希 == 计划哈希、未撤销、未过期；
  3. 引用源哈希与冻结哈希一致（引用已变化 → 拒绝 + 计划失效）；
  4. 逐目标（含每级跳板引用）`KnownHosts::status()` 为 `Known`（文件级排除 Unknown；真正的 Mismatch 无呈现密钥无法文件级判定，交给下一层）；
  5. 审计通道可用（`AuditSink` 预检/写入启动事件失败 → 阻断）；
  6. 通过后创建运行记录（`排队`），将冻结计划交给 `PlanExecutor` 在全局 tokio runtime 上异步执行，立即返回 run_id。
- `PlanExecutor` trait：输入冻结计划（快照内容、目标、预算）与逐目标瞬态连接材料，按目标推进步骤并回报状态迁移；批量执行提案提供真实实现，本提案用 fake executor 完成全部网关/状态机测试（TDD 无需真实 SSH）。
- 连接期主机密钥：执行器沿用既有连接层校验；收到 `HostKeyMismatch` 时网关将该目标记为失败、使计划失效并停止发起后续目标（主机密钥异常 → 授权失效）。Unknown 在第 4 步已被文件级检查拦截，系统代发路径永远不会触发无人值守 TOFU。
- 备选「把校验散在执行器里」被否决：校验必须先于连接且集中一处，否则每个新入口（MCP/定时）都要重新做对一遍。

### D5：九态状态机与迁移表

- 运行九态：`排队、等待批准、运行、成功、失败、超时、取消请求、已确认停止、结果未知`。合法迁移以常量表定义（同 D3 的纯函数风格）：
  - `等待批准 → 排队`（获批准）、`等待批准 → 已确认停止`（被拒/撤销，未发出任何操作）；
  - `排队 → 运行`、`排队 → 已确认停止`；
  - `运行 → 成功 | 失败 | 超时 | 结果未知 | 取消请求`；
  - `取消请求 → 已确认停止 | 结果未知`（无法确认远端已终止时落 `结果未知`，与批量执行 design D2 步骤级迁移一致）。
- 逐目标步骤状态取同一九态词汇：连接中断且无退出码 → `结果未知`（不映射为失败，更不是成功）；预算超时 → `超时`；用户停止且无退出码 → `结果未知` 保留。
- 「停止等待 ≠ 远端已停止」：`取消请求` 态下网关不假设远端进程已终止，只有执行器确认停止流程完成（或连接已断）才落 `已确认停止`，且已发出步骤各自保留真实终态。
- FFI 的启动/暂停/撤销接口只改状态机输入，不做业务判断之外的事情；所有规则都在 core。

### D6：审计衔接为最小 trait 语义

- panda-core 定义 `AuditSink`（记录计划关联的批准/尝试/结果/拒绝/撤销/暂停事件 + 可用性预检），网关在任何新步骤前要求预检通过，写入失败或预检失败 → 拒绝并发起阻断（可区分错误 `AuditUnavailable`）。
- 真实实现与记录格式、删除缺段可见性由 add-command-audit-trail 交付；add-batch-remote-execution 消费同一 `AuditSink` 端口（见其 design D1，不重复定义）。本提案 tasks 只用 fake audit（可注入失败）验证阻断逻辑。两提案并行评审，接口签名以评审结论为准（见 Open Questions）。

### D7：FFI 契约与手动路径边界

- 新增同步导出：`create_execution_plan`、`get_execution_plan`、`list_execution_plans`、`submit_execution_plan`、`approve_execution_plan`、`reject_execution_plan`、`revoke_execution_plan`、`pause_execution_plan`、`start_execution_plan_run(plan_id, credentials, trust_on_first_use) -> run_id`、`get_execution_run_status(run_id)`、`request_execution_run_stop(run_id)`。异步执行在既有全局 runtime；`start_*` 网关校验（纯文件 IO）后快速返回运行标识，模式与 `start_transfer` 一致。
- `PandaError` 新变体：`UnknownExecutionPlan`、`ExecutionPlanState(String→结构化状态错误)`、`AuthorizationInvalid { reason }`、`PlanReferenceChanged { reference }`、`HostKeyNotVerified { host, status }`、`GatewayRejected { reason }`、`AuditUnavailable`。Swift 可按变体分支，与现有错误分类惯例一致。
- 凭据：`start_execution_plan_run` 接受逐主机瞬态 password/passphrase 参数（与 `test_connection` 现状一致），计划与审计只存 `*_ref`；不新增任何凭据读取接口。
- 手动路径：`shell_open` / `test_connection` / `sftp_*` 签名与行为不变，不接网关——手动输入本身即该次操作指令。网关只服务新增的计划执行入口；未来 MCP/定时入口 MUST 复用该入口（写入 spec，防绕行）。

### D8：Swift 审核 UI 与双端

- 新增计划审核视图：逐目标命令、身份（用户名 + 凭据引用有无，不显示秘密）、跳板链、数据流向、资源预算、验证步骤的只读预览 + 确认/拒绝按钮；批准/拒绝/撤销调用 FFI。运行状态页展示九态与逐目标状态，结果未知以醒目样式区分失败。
- 双端共享同一视图与模型层；平台条件编译仅限窗口尺寸等 UI 差异。iPadOS 无定时入口，本提案也不引入定时；计划在双端均为人工触发。网关与状态机在 Rust，双端行为零差异。

## Risks / Trade-offs

- [TOML 单文件在多计划 + 频繁运行状态更新下的写放大] → 计划与运行记录分文件；运行状态仅在迁移时落盘；计划量级由人工审核天然受限。若后续出现性能压力，迁移 SQLite 时计划结构体不变。
- [fake executor 通过但真实执行器行为偏差（如停止语义、输出上限）] → `PlanExecutor` trait 以契约测试固定语义（必须在预算内回报、必须为每个已发目标给出终态或结果未知）；真实执行器提案的 tasks 中复用同一契约测试套件。
- [并行提案接口漂移（AuditSink、PlanExecutor、跳板链字段）] → trait 保持最小面；本提案 Open Questions 显式列出对齐点；集成任务置于 tasks 尾部并在批量执行提案中接线。
- [批准记录被本地文件篡改（TOML 可手改）] → 本地攻击者本可改任何本地状态；网关校验哈希一致性可防「旧授权套新内容」，不承诺防本地_root 篡改（与 known_hosts 同级威胁模型）。完整性机制（签名等）留给审计提案统一考量。
- [运行记录与审计记录的双写一致性] → 审计为可信边界记录，运行记录为 UI 状态；阻断规则保证「审计不可用 → 不产生新步骤」，宁可少执行也不产生无审计的操作。

## Migration Plan

- 纯新增模块与文件：`plans.toml` / `plan_runs.toml` 首次使用时创建，不影响既有 hosts/groups/credentials 数据，无数据迁移。
- FFI 只增不改：现有导出签名不变，Swift 绑定重新生成即可。
- 回滚：移除新模块与 UI 入口即可，无残留状态依赖。

## Open Questions

- `AuditSink` 的精确方法签名与事件枚举，需与 add-command-audit-trail 评审结论对齐（语义已定：预检 + 追加 + 失败可观测）。
- 授权过期（`expires_at`）的默认策略与 UI 设置项：本提案支持可选有效期字段，默认不过期；是否在审核 UI 提供设置、默认值多少，留给评审。
- 运行记录与审计存储最终是否合并（若审计提案选定 SQLite/日志文件方案，`plan_runs.toml` 可改为其上的视图）——存储层可替换，状态机与网关语义不受影响。
- 计划创建入口的 UX 归属（批量执行页 vs 独立计划页）由 add-batch-remote-execution 的 UX 设计决定；本提案只约束审核预览内容。
