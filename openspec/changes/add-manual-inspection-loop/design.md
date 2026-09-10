# add-manual-inspection-loop 设计

> 状态：草案 | 关联：proposal.md、specs/inspection-*/spec.md、路线图 8.4 / 8.7 / 13.1 / 14.8

## Context

现状与约束（动机见 proposal.md 的 Why）：

- `crates/panda-core/src/ssh.rs` 已有 exec 原语（`exec` / `exec_with_timeout`，返回 `ExecOutput { stdout, stderr, exit_status: Option<u32> }`），exit code 可能为 `None`（未收到退出码）——巡检采集与「未收到退出码不得默认成功」的九态语义直接对应。
- 连接监控（`openspec/specs/connection-monitoring/spec.md`）仅覆盖 Panda SSH 自身连接的传输状态，不含任何远程主机指标；本提案的采集是真实 exec，二者边界必须显式（见 specs/inspection-measurements 的边界需求）。
- `openspec/specs/snippets/spec.md` 的片段能力已被实现并被方案以 SnippetRef 引用；本提案不改片段规格。
- 三个并行提案提供共享契约，本提案按契约对接并在任务中显式标注集成点：`add-execution-plan-authorization`（计划与授权）、`add-batch-remote-execution`（CommandSource、有界执行、九态、连接所有权）、`add-command-audit-trail`（审计关联与缺段）。`resolve-baseline-conflicts` 消解凭据基线，本提案对凭据一律表述为「凭据引用（*_ref）+ 连接层按授权使用」，不断言具体存储介质。

## Goals / Non-Goals

**Goals（设计层）：**

- 三分离（8.7 决策 1）在模型与存储上的落地方式；方案版本化的内容哈希方案。
- 首批指标集确认与逐指标测量 / 失效边界定义；三类解析器与阈值评估器的选型。
- 执行记录的 SQLite schema、迁移、容量估算与保留策略；与审计存储的关系。
- 闭环 runner 的 trait 隔离与授权检查接入点；FFI / Swift 分层。
- HTML 导出任务组的技术边界（模板候选、转义、单文件、缺段展示）。

**Non-Goals：** 见 proposal.md 的 Non-goals 一节（定时巡检、AI 摘要 / 归因、重复任务、跨主机趋势分析、向量检索、拓扑发现、PDF）。设计层补充：不引入 sqlite-vec；首版 HTML 报告不含图表脚本（见决策 D8）；不做审计库本身的 schema 设计（属 add-command-audit-trail）。

## Decisions

### D1. 三分离的模型与版本化

- `InspectionProfile`：TOML 文件存储于 store 根 `inspection/profiles/<id>.toml`，与主机配置的存储方式一致；内容含全部采集项（指标 key、CommandSource、解析规则、阈值）、验证规则与适用环境条件。
- 版本标识 = 方案完整规范内容的 SHA-256（序列化规范化后计算），保存即产生新版本；历史版本不单独快照全量内容，而是**内容寻址**：`inspection/versions/<hash>.toml` 在每次保存时写入不可变副本，保证「历史版本标识与内容可查询且不变」。备选方案「仅存版本号 + 修改历史」被否决：版本号无法验证内容一致性，无法满足「片段 / 方案更新不扩散到已审核计划」的可核验性（13.1「仅缓存文本不能证明下次语义相同」）。
- 执行记录只存 run 发生时的 `profile_version`（哈希）与 `plan_version`（授权提案的版本标识），永不回写。
- 学习 / AI / Skill / 记忆相关组件在本提案中不存在；即便后续引入，也不持有方案版本签发、授权签发或审批状态修改能力（共享契约边界，在此声明归属）。

### D2. 首批指标集（从 14.8 十个候选中选 5）与逐指标测量 / 失效边界

进入首批：**CPU 利用率、负载 / 核、内存使用率、文件系统容量、失败服务**。逐项定义如下（均为本提案自查后的定义，不引用未核验的外部基准值）：

1. **`cpu.utilization`**（CPU 利用率，%）
   - 测量：单条采集命令内读取两次 `/proc/stat` 的 `cpu` 聚合行（`cat /proc/stat; sleep <窗口>; cat /proc/stat`），本地计算差值；利用率 = 1 − idle 差值 / 总量差值；iowait 计入忙侧并在记录中标注口径。窗口默认 3 秒、可配 1–5 秒；窗口起止取本地收到两段输出的时刻（近似）并在记录中如实标注。
   - 失效边界：两次样本间计数器回退 / 重置 →「不可用」（原因：计数器重置）；命令被预算截断致窗口不足 →「不可用」（原因：采样窗口不足）；**只采一次样本不产生利用率值**，同样记「不可用」，MUST NOT 把单次快照当作利用率；`/proc/stat` 不可读 →「不可用」（权限不足）；非 Linux →「不支持」。
   - 入选理由：故障初筛最直接信号；纯 `/proc` 读取无外部依赖；同时为「计数器差值 + 重置检测」契约提供测试载体。
2. **`load.per.cpu`**（负载 / 核，无量纲比值）
   - 测量：`/proc/loadavg` 第 1 字段（1 分钟负载）÷ 逻辑核数（`nproc`）；原始 loadavg 行全文存入证据摘要。仅取 1 分钟值；5 / 15 分钟不进首版结果。
   - 失效边界：loadavg 缺失（非 Linux）→「不支持」；核数获取失败 →「不可用」；检测到 cgroup CPU 配额与核数口径不一致（quota/period ≠ 核数）时 → 记「不支持」并展示原因（首版不做容器配额口径，避免用物理核数低估）。
   - 入选理由：与利用率互补（运行队列视角），单命令可得；强制明确「负载与 CPU 百分比是不同量纲」，报告分别展示不合并。
3. **`memory.usage`**（内存使用率，%）
   - 测量：`/proc/meminfo` 的 `MemAvailable` / `MemTotal`，使用率 = 1 − MemAvailable/MemTotal。
   - 失效边界：内核过旧无 `MemAvailable` →「不可用」（MUST NOT 回退用 `free` 输出列名猜语义，列名随版本变化）；`MemTotal` 为 0 →「不可用」（分母为零不当作 0% 或告警）；字段缺失 →「不可用」。
   - 入选理由：KV 解析最小样例、初筛核心信号。
4. **`fs.capacity`**（文件系统容量，每挂载点多值：字节 + %）
   - 测量：`LC_ALL=C df -P -k`，逐挂载点记录总量 / 已用 / 可用 / 使用率 / 挂载点；默认排除伪文件系统（tmpfs、devtmpfs、overlay、squashfs 等），网络文件系统（nfs/cifs）默认排除——排除清单按环境可配置；只读挂载在记录中标注。
   - 失效边界：逐挂载点独立判定：df 对个别挂载点报错 → 该挂载点「采集失败」，其余挂载点不受影响（部分失败语义的载体）；解析异常 →「不可用」；不需要特权。
   - 入选理由：磁盘满是最高频初筛信号；多值结构天然验证「部分失败不得标全部正常」。
5. **`systemd.failed_services`**（失败服务，计数 + 单元列表）
   - 测量：`systemctl --no-pager --no-legend --type=service --state=failed list-units`，显式系统实例（不做 user 实例）；结果为单元列表与计数。
   - 失效边界：PID 1 非 systemd 或 systemctl 不存在 →「不支持」；查询报错 →「采集失败」；systemd 返回权限错误 →「不可用」（权限不足）。数量不替代影响等级：首版只展示列表与计数，关键性由人工复核判定，不自动评级。
   - 入选理由：即路线图「一个故障初筛样例」的落点。
- **排除候选与理由**：Swap（分母为零语义复杂、与内存使用率部分重叠）→ 第二批；inode（`df -i` 跨文件系统支持差异大）→ 第二批；僵尸进程（瞬时值易抖动，单次人工巡检价值低）；时间同步（chrony/ntpd 工具差异大）→ 第二批；登录失败（日志来源 / 轮转 / journalctl 权限复杂，偏安全审计方向，宜单独提案）。

### D3. 采集命令组织与 CommandSource

每个采集项 = 一条命令（内联字符串或 SnippetRef）；一台主机 N 个采集项 = N 条命令 = 批量执行契约中的 N 个任务（主机 × 命令）。计划展开时把每个采集项的命令与「展开后参数」（如 CPU 采样窗口、df 排除清单）代入，**冻结方案版本 + 片段内容版本**（D1 内容哈希）写入计划。预算：并发、单主机输出上限（对全部采集项合计生效）、总时长均来自计划资源预算，由批量执行契约强制。

### D4. 解析器（三类）

- **KV**：`key: value [unit]` 与 `key=value` 两式，忽略空行与注释行；单位后缀（如 `kB`）作为独立字段记录。用于 meminfo。
- **正则**：Rust `regex` crate（已在本仓库依赖树风格内、Apache/MIT 双许可），带命名捕获组；捕获值 + 单位声明来自指标定义。
- **JSON 路径**：首版实现为 serde_json 的 RFC 6901 JSON Pointer 子集（`/a/0/b`），**不引入完整 JSONPath crate**（避免 wildcard 语义争议与额外依赖）；解析规则版本标注 `json-pointer@1`，wildcard 需求出现时再评估完整实现。用于未来 JSON 输出类指标；首批指标主要用 KV 与正则，JSON 解析器随契约一起实现并有独立测试。
- 通用行为：exit code ≠ 0 →「采集失败」（附 stderr 摘要）；exit 0 但解析失败 →「不可用」+ 解析错误；解析成功留存来源输出摘要（截断，见 D6）。所有解析器纯函数、跨平台、全量单测。

### D5. 阈值评估

- 规则结构：`{ metric_key, op, value, scope }`，scope 支持环境默认 / 按主机 / 按挂载点（仅 fs.capacity）覆盖；`op ∈ {>, >=, <, <=, ==}`，全部为可解释规则，不做复合表达式引擎。备选「表达式 DSL」被否决：不可解释、难以展示、AI 扩权风险面大。
- 初版默认值（**草案，按环境可改，未经行业基准验证**——路线图明确不把未复核数值当官方默认）：`cpu.utilization ≥ 95%`（3 秒窗口）、`load.per.cpu ≥ 2.0`、`memory.usage ≥ 90%`、`fs.capacity 使用率 ≥ 90%`、`systemd.failed_services > 0`（仅展示不评级）。验证方式：试用中按误报 / 漏报与处置成本反馈调整，阈值历史随方案版本演进。
- 触发 = 结果展示（指标、实际值、阈值、规则说明）；无任何自动处置通道。「忽略告警」只写复核记录，不反写方案。

### D6. 执行记录存储（SQLite）

- **选型**：`rusqlite`（MIT）+ `bundled` feature（静态编译 SQLite，SQLite 本体公有领域），Apache-2.0 兼容；iOS 静态链接由 bundled 保证，`cargo check --target x86_64-unknown-linux-gnu` 验证 Linux 可编译。备选 redb/sled 被否决：巡检需要关系查询与聚合，且 SQLite 是 8.7 决策 2 的既定方向。sqlite-vec 不引入（Non-goal）。
- **位置**：store 根（`init_store(config_dir)` 注入；iPadOS 为 App Group 容器）下 `inspection/inspection.db`——复用既有注入机制，不加平台分支。
- **Schema（v1，全部含 run 维外键）**：
  - `runs(id, profile_id, profile_version, plan_id, plan_version, trigger, status, started_at, finished_at)` —— status 用九态之一（枚举来源为批量执行契约，不自定义新态）；
  - `attempts(id, run_id, host_id, seq, state, started_at, finished_at, exit_code NULL, output_truncated, error_kind, error_message)` —— exit_code 为 NULL 即「未收到退出码」，展示为失败 / 结果未知；
  - `measurements(id, run_id, attempt_id, host_id, metric_key, value_num NULL, value_text NULL, unit, window_start, window_end, collected_at, quality, reason, parser_version)` —— quality ∈ {valid, unavailable, unsupported, collect_failed, stale}；
  - `evidence(id, run_id, attempt_id, command_excerpt, stdout_excerpt, stderr_excerpt)` —— 截断摘要（默认每段 ≤2 KiB，可配），完整输出不落盘（最小留存）；
  - `reviews(id, run_id, target_kind, target_id, verdict, reviewer, reviewed_at, note)`；
  - `schema_migrations(version, applied_at)`，顺序迁移，启动时校验。
- **崩溃恢复与并发**：WAL 模式 + 事务写入（一次运行一个事务组）；本提案仅人工触发，无定时并发写。
- **容量估算（不凭「数十万条无压力」断言）**：参数取 50 主机 × 5 采集项、每日 2 次人工巡检；行数据（指标 + 尝试）≈ 3 KB / 运行，证据摘要上界 50×5×2 KiB = 500 KB / 运行、典型输出远小于上界（meminfo ≈1.3 KiB、df <4 KiB、failed 列表常为空），现实估算 100–200 KB / 运行。年约 730 次运行 → **典型 ~100 MB / 年、上界 ~400 MB**，SQLite 完全可承载；保留期默认 12 个月（可配），到期清理保留 `runs` 头记录与「已清理」标记以维持缺段可见，另提供手动清理入口。
- **与命令审计存储的关系**：不同库（审计库 schema 属 add-command-audit-trail）；通过 `plan_version` / `run_id` / `attempt_id` 稳定标识关联，巡检结果视图经审计查询接口读取缺段信息。不要求同库（8.7 决策 2）。

### D7. 闭环 runner 与授权接入

- `panda-core` 新增 `inspection` 模块：`profile` / `metric` / `parser` / `threshold` / `record` / `runner`。
- runner 依赖两个注入 trait（隔离外部依赖、全量 fake 测试）：
  - `InspectionExecutor`：由批量执行契约实现（发起主机×命令任务、九态回调、取消、超时、输出上限）——本提案先以 fake 实现完成 runner 全部测试，集成任务对接真实实现；
  - `Clock`：注入时间源（采集时刻、过期判定、时间偏差记录）。
- **授权强制检查点**：runner 在发出任何远端命令前调用执行计划授权契约的检查入口（Rust 执行入口统一实施，与 UI 状态无关）；检查失败（无授权 / 已失效 / 审计写入失败或完整性无法核验）→ 不发起、返回可区分错误。
- 连接所有权：巡检任务经批量执行契约拥有自己的 Transport，不借用终端标签连接（与 specs 的「只读采集仍需授权」场景一致）。

### D8. 应用内报告（首版必含）与 HTML 导出任务组

- **应用内报告（首版）**：SwiftUI 按主机分组展示指标值 / 单位 / 采集时刻与窗口 / 质量状态 / 阈值结论 / 解析错误 / 截断标记 / 审计缺段；六类分栏（有效、阈值异常、不可用、不支持、采集失败、过期 + 缺段）。数据全部来自 FFI 查询接口，Swift 不做业务计算。
- **HTML 导出（提案内后续任务组，不阻塞首版）**：
  - minijinja（MPL-2.0，兼容 Apache-2.0）为模板候选；**uPlot 延后**：首版 HTML 不含图表脚本，规避「脚本数据上下文」的大半风险面，图表作为后续单独验证任务（打包体积、iOS 兼容）再引入。
  - 转义策略：autoescape 仅是基线；模板规范要求远端文本只出现在文本 / 属性上下文且经显式转义，嵌入脚本的数据（当前无，保留规则）经 serde_json 序列化并把 `<` 转义为 `\u003c` 防止 `</script>` 逃逸；URL 上下文首版不存在（报告零外链）。恶意样本（`<script>`、`</script>`、引号、反引号、换行）各上下文的注入测试为该任务组的验收项。
  - 单文件离线：CSS 内联、测试断言产物无 `<link>` / `<script src>` / `http(s)://` 引用；导出前展示范围，导出不发任何网络请求。
  - 内置模板随二进制只读嵌入；用户副本存 store 根并记录来源模板版本；渲染失败回退纯文本摘要。
  - 平台差异：macOS 经 NSSavePanel 落盘，iPadOS 经系统分享导出——属允许的平台服务 `#if os()` 差异。

### D9. FFI 与 Swift 分层

- `panda-ffi` 新增同步导出（异步在既有全局 tokio runtime `block_on`）：方案 CRUD / 指标注册表查询 / 生成计划参数 / 发起执行（带计划与授权上下文）/ 取消 / 查询运行与结果 / 写复核 / 报告数据 / 导出 HTML（返回文件路径或文本，平台由 Swift 决定落盘方式）。全部简单值类型（Record / Enum / Optional / String / 整数）；密钥材料不经过 FFI 落盘，凭据仅以 `*_ref` 出现在计划与记录中，连接时由 Swift 平台层取出后作参数传入（现有约定）。
- Swift 侧新增巡检界面（方案列表 / 编辑器、发起向导：目标选择 → 审核展示 → 执行进度 → 结果分栏 → 复核入口）；`#if os()` 仅用于导出面板与键盘等 UI / 平台服务差异；iPadOS 不出现定时相关入口。

## Risks / Trade-offs

- [三个并行提案契约尚未合并，runner 集成可能返工] → `InspectionExecutor` / 授权检查以 trait 抽象，fake 先行完成全部测试；集成任务置于任务序列末端并显式标注依赖。
- [`df` / `/proc` 输出在不同发行版、Locale 下差异] → `LC_ALL=C` + POSIX 格式 + 解析失败一律记「不可用」不猜测；首批指标在 Ubuntu / Debian 容器与 macOS 本机 SSH 回环上验证（open questions 跟进）。
- [iOS 静态链接 SQLite 失败] → bundled feature + 构建验证任务前置；失败则回退为 TOML + JSON 行文件存储（仅作应急备选，需重新评审）。
- [证据摘要可能含远端敏感文本（motd、路径）] → 摘要截断 ≤2 KiB、仅本地库存储、凭据类材料不采集（采集命令由用户在方案中声明并在审核时可见）；提供按保留期与手动清理。
- [默认阈值未经验证造成误报 / 漏报] → 全部标注草案、按环境可改；触发展示附规则说明；以试用反馈迭代，不自动放宽。
- [JSON Pointer 子集与用户预期的 JSONPath 不一致] → 解析规则版本显式标注 `json-pointer@1` 并在 UI 说明支持范围。
- [九态映射偏差（尤其取消 / 结果未知）] → 状态枚举唯一来源为批量执行契约；`exit_code: None` 一律不映射为成功；取消语义测试为 runner 验收项。

## Migration Plan

全新能力，无存量数据迁移：schema 从 v1 起以 `schema_migrations` 顺序演进；回退 = 移除 UI 入口并保留 `inspection/` 目录数据（或整体删除），不影响主机 / 片段 / 审计等既有功能。归档时将四个新 capability 的 delta 合并回 `openspec/specs/`。

## Open Questions

- `fs.capacity` 伪文件系统与网络文件系统默认排除清单，需在真实发行版（Ubuntu / Debian / RHEL 容器）上验证后定稿——不影响契约与任务拆分，在实现任务内完成验证。
- systemd 探测方式（`/proc/1/comm` vs `command -v systemctl`）在无 systemd 容器环境的行为细节。
- 复核记录「执行人」的表示（本地用户名 / 应用内身份），需与 add-command-audit-trail 的执行人表示对齐后统一。
