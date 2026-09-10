# 任务：命令审计跟踪（add-command-audit-trail）

> 依据 spec deltas（specs/command-audit/spec.md）与 design.md 决策拆分；严格 red-green-refactor：每组先列失败测试任务，再列实现任务；每个任务粒度为一次可验证提交。涉及 FFI 与工程结构的任务完成后须按 `build-rust.sh` → `xcodegen` → 双端 `xcodebuild` 验证。

## 1. 审计记录模型（crates/panda-core 新增 audit 模块）

- [ ] 1.1 测试：记录模型与结果状态——正常流程：构造 CommandAttempt/CommandOutcome、SftpAttempt/SftpOutcome、Clearance、Recovery 的 serde 序列化往返，attempt_id 关联与字段完整（记录编号、时间、命令文本、目标主机、执行主体、计划引用、证据引用）；意外操作：非法组合被拒绝（Outcome 未收到退出码却携带 exit_status、被拒终态携带退出码、SFTP 记录混入命令字段）；边界条件：Attempt 无 Outcome 的未知态、空命令文本、超长命令文本、计划引用为 None、`remote_state_known=false` 的强制约束
- [ ] 1.2 实现：`AuditRecord` tagged 枚举、`AuditOutcome` 结果状态（成功/失败/超时/取消请求/已确认停止/结果未知/被拒绝）、`PlanRef { plan_id, content_version }`、构造校验规则；`cargo test -p panda-core` 全绿

## 2. JSONL 分段存储与段清单（design 决策 1/2）

- [ ] 2.1 测试：审计存储——正常流程：追加→读取往返、序号由存储层单调分配、段达阈值封存并写清单（首末序号/记录数/段内链式摘要/前段清单摘要）、`state.json` 续写、重启后序号衔接；意外操作：只读目录/注入 IO 失败时写入错误上抛不静默、文件被截断产生残缺尾行时读取标记「写入中断」而非静默丢弃；边界条件：空库、单条记录、超长单行、`state.json` 损坏时的可区分错误
- [ ] 2.2 实现：`AuditStore`（append 分配序号、按段扫描、段清单与段内摘要链写入、`init_store` 时创建 `audit/segments/` 与 `state.json`）；`cargo test -p panda-core` 全绿

## 3. 完整性核验与缺段分类

- [ ] 3.1 测试：完整性核验——正常流程：完整库核验为 Verified；含授权清理留痕的库将留痕区间归类为「授权清理」缺段；意外操作：段内记录被修改/重排/删除时核验失败并定位分段、末段记录数少于清单时报告尾部截断；边界条件：段间清单链断裂判为 Unverifiable、整体替换为旧副本判为 Unverifiable、仅含清理留痕的库、清空运行日志不影响核验结果
- [ ] 3.2 实现：`verify()` 与 `IntegrityReport`（Verified / Compromised(定位) / Unverifiable；缺段四分类：授权清理、异常缺失、证据不足、不可验证）；`cargo test -p panda-core` 全绿

## 4. 合法清理与删除留痕

- [ ] 4.1 测试：清理留痕——正常流程：清理编号区间写入 Clearance（范围/原因/时间/操作主体），读取与展示呈现「授权清理」缺段；意外操作：倒置、越界、与留痕重叠的清理范围被拒绝，留痕自身不可被清理；边界条件：一次清理全部历史、连续多次清理的留痕序列可追溯、清理后新写入序号仍单调衔接
- [ ] 4.2 实现：`clear(range, reason)` 与 Clearance 记录、核验对清理区间的豁免逻辑；`cargo test -p panda-core` 全绿

## 5. 隐私与脱敏

- [ ] 5.1 测试：脱敏——正常流程：含口令赋值、私钥块、长 base64/hex 片段的命令被 `[已脱敏]` 占位且 `redacted=true`，主机/时间/状态等元数据完整保留；意外操作：不含秘密的命令原文保真且 `redacted=false`，脱敏不改变命令的提交行为语义（记录层替换、执行层仍用原文）；边界条件：空命令、同一命令多处秘密、超长行脱敏不 panic、执行层原文不在审计存储任何文件中出现
- [ ] 5.2 实现：`redact()` 启发式与标记字段，接入 Attempt 记录构造；`cargo test -p panda-core` 全绿

## 6. 阻断闸门与恢复流程（design 决策 4）

- [ ] 6.1 测试：AuditGate——正常流程：Open 状态放行、恢复流程（校验→补写 Recovery→重核验→Open）后放行；意外操作：注入审计写入失败/存储耗尽后闸门转 Blocked 并拒绝后续检查请求（返回可区分错误）、完整性 Unverifiable 时转 Blocked；边界条件：Blocked 状态经 `state.json` 持久化跨重启持续、恢复失败保持 Blocked、阻断前已写入 Attempt 无 Outcome 的在途操作保持结果未知且恢复时补写 Recovery 记录
- [ ] 6.2 实现：`AuditGate` 状态机、持久化、`recover()`、可区分错误类型；学习/AI 入口无闸门写权限（仅只读）；`cargo test -p panda-core` 全绿

## 7. exec 执行路径审计接入

- [ ] 7.1 测试：exec 审计——正常流程：成功 exec 产生 Attempt+Outcome（成功、退出码、输出长度+SHA-256 证据引用）；连接探测等系统代发调用标注执行主体、计划引用为空，批量/巡检调用经统一入口填充 PlanRef；意外操作：建连/认证失败产生 Attempt+失败（未达远端）记录、闸门 Blocked 时 exec 请求被拒且不建立通道、授权拒绝路径写入被拒终态；边界条件：非零退出码原样保留、超时记录（超时态、退出码空、`remote_state_known=false`）、断线记录（结果未知）、并发 exec 序号连续
- [ ] 7.2 实现：`ssh.rs` exec 路径两段式记录 + 闸门前置检查接入；`cargo test --workspace` 全绿

## 8. SFTP 操作审计接入

- [ ] 8.1 测试：SFTP 审计——正常流程：上传/下载/删除文件/删除目录/创建目录各产生 Attempt+Outcome（操作类别、目标路径、数据流向、终态）；意外操作：操作失败终态、冲突决策（覆盖/跳过/取消）入记录、闸门 Blocked 时变更类操作被拒；边界条件：下载含秘密文件仅记录元数据不含正文、超长路径、并发操作序号连续、目录浏览不产生审计记录
- [ ] 8.2 实现：panda-core SFTP 变更类操作记录点与闸门接入；`cargo test --workspace` 全绿

## 9. FFI 审计接口（crates/panda-ffi）

- [ ] 9.1 测试：FFI 导出——正常流程：`audit_query`（分页、缺段标注）、`audit_integrity_report`、`audit_clear`、`audit_recover` 的返回 Record/Enum 映射正确、同步语义（全局 runtime block_on）；意外操作：审计库损坏时返回可区分错误而非 panic、Blocked 状态下 clear/recover 之外的操作被拒；边界条件：空库查询、范围参数倒置、超大范围分页
- [ ] 9.2 实现：四个 `#[uniffi::export]` 同步函数与值类型；`cargo test --workspace` 全绿，`build-rust.sh` 通过

## 10. Swift 双端审计查看（apple/PandaSSH）

- [ ] 10.1 测试：模型与视图模型（XCTest）——正常流程：`AppBackend` 审计记录/完整性报告到展示模型的映射、缺段四分类与完整性三态的展示状态；意外操作：Unverifiable/Blocked 状态的呈现路径、审计查询错误的用户可见提示；边界条件：空审计历史、超长列表分页加载、清理/恢复入口的禁用与确认条件
- [ ] 10.2 实现：`MockBackend` 内存审计实现（Preview/测试用）、`AuditHistoryView` 双端共享页面（记录列表、缺段条带、完整性横幅、清理与恢复入口、阻断原因提示），macOS 窗口/菜单入口与 iPadOS 侧栏入口仅导航容器差异，无业务 `#if os()`；`build-rust.sh` → `xcodegen` → macOS/iPadOS `xcodebuild` 通过，改动 target 的 XCTest 全绿

## 11. 门禁与收尾

- [ ] 11.1 全量回归：`cargo test --workspace` 全绿；`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 达标（lines ≥ 95%、regions ≥ 95%）；Swift 改动 target 测试通过
- [ ] 11.2 一致性核对：实现与 spec deltas 逐条对照（结果状态语义、缺段四分类、阻断契约、脱敏标记、交互覆盖未知边界），更新任务勾选状态，准备评审与归档
