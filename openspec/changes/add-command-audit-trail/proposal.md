# 命令审计跟踪（add-command-audit-trail）

> 状态：草案 | 创建日期：2026-09-09 | 关联路线图：brainstorming-ai-era-roadmap.md 4.4、5.1（阶段表第一行「首个执行闭环」）、14.2、14.3
> 并行提案：add-execution-plan-authorization、add-batch-remote-execution、add-manual-inspection-loop、resolve-baseline-conflicts

## Why

路线图将「首个纵向闭环」的验收重点定为：正常链路、失败/未知、缺段、篡改与写入中断。当前应用代发命令（`exec`）与 SFTP 操作只有 runtime-logging 的环形缓冲与轮转文本日志——它面向排查展示，不承担审计职责：没有结构化记录模型、没有计划/授权引用、没有可区分的结果状态（超时或断线无法与「远端未执行」区分、缺退出码被静默忽略）、没有记录连续性检查与删除缺段展示。批量执行与人工巡检提案在接入前，需要本提案先定义并实现审计契约（记录模型、缺段语义、阻断语义），否则系统代发步骤将处于「不可审计」状态。

## What Changes

- 新增 `command-audit` 能力：在 `crates/panda-core` 建立独立于 runtime-logging 的结构化审计存储与校验逻辑，Swift 仅经 FFI 只读消费。
- 审计记录模型：应用代发命令（`exec`）与 SFTP 变更类操作的审计元数据——实际提交内容、目标主机、执行计划/授权引用（本阶段可空，为批量/巡检预留）、执行主体、时间、结果状态（成功/失败/超时/取消请求/已确认停止/结果未知/被拒绝）、验证证据引用。缺退出码 MUST NOT 填零；超时或断线 MUST 标记远端执行状态未知。
- SFTP 审计：路径/目标、操作类别、冲突决策、终态；不记录文件正文。
- 连续性与缺段：全局单调记录编号、完整性核验（分段清单 + 段间链式摘要）；缺段展示区分授权清理/异常缺失/证据不足/不可验证；合法清理保留清理留痕；读取、验证与展示不得绕过完整性检查。
- 隐私与脱敏：秘密不得进入一般审计负载；脱敏/隐藏内容明确标记，保留非敏感关联元数据。
- 阻断语义：审计写入失败、存储耗尽或完整性无法核验时，系统代发任务阻断新步骤、提示用户、保留已发出操作的未知状态与恢复记录（本提案定义契约，批量执行/巡检提案消费）。
- 存储选型：追加式 JSONL 分段文件（含段清单与链式摘要），决策与取舍见 design.md。
- FFI 新增同步导出的审计查询接口（记录读取、缺段报告、完整性状态）。

## Capabilities

### New Capabilities

- `command-audit`：本地命令与 SFTP 操作审计——审计记录模型与结果状态语义、SFTP 审计边界、记录编号连续性与缺段分类、合法清理留痕、隐私脱敏、完整性核验与本地可信边界、系统代发阻断契约、交互 shell「命令覆盖未知」边界声明，以及与 runtime-logging 的职责区分。

### Modified Capabilities

（无。`ssh-connection`、`sftp-transfer` 等既有规格描述的执行行为本身不变，本提案只在其执行路径上追加审计记录点；`runtime-logging` 规格不变，审计与其职责显式区分。）

## Impact

- `crates/panda-core`：新增 `audit` 模块（记录模型、JSONL 分段存储、完整性核验、缺段分类、脱敏、阻断闸门、清理留痕）；`ssh.rs` 的 `exec`/`exec_with_timeout` 与 SFTP 操作路径增加审计记录点；`init_store` 初始化审计存储根（配置目录下 `audit/` 子目录）。无新增外部依赖（serde_json、sha2 已在依赖中）。
- `crates/panda-ffi`：新增同步导出的审计查询与验证接口（在既有全局 tokio runtime 上 `block_on`，简单值类型 Record/Enum）；审计写入发生在 core 内部执行路径，密钥材料不经过 FFI，凭据按「凭据引用（*_ref）+ 连接层按授权使用」处理，审计记录只含凭据引用标识、绝不含凭据材料。
- `apple/PandaSSH`：`AppBackend` 协议新增审计查询方法（Mock 提供内存实现供 Preview/测试）；新增审计历史与缺段报告视图（双端共享 SwiftUI，纯 UI）。授权强制检查仍在 Rust 执行入口统一实施，UI 展示不替代执行前检查。
- 存储：macOS 为 `~/.panda-ssh/audit/`，iPadOS 为 App Group 容器内 `audit/`；命令审计存储与巡检数据职责分开（路线图 8.7 决策 2），不要求同库。
- 任务拥有自己的 Transport/连接（不从终端标签隐式借用），审计记录通过任务/连接标识关联，不依赖共享连接。

## Non-goals

- 交互 shell 完整命令记录与 shell integration（OSC）信号解析——后续「交互记录深化」阶段。
- 可选终端录像 / asciicast 回放。
- AI 记忆或学习系统消费审计的派生视图。
- 修改 `runtime-logging` 规格（其环形缓冲、轮转、展示行为不变）。
- macOS 定时任务相关内容（定时执行不在本批范围；iPadOS 不支持定时执行）。
- 授权决策本身（计划审批、授权状态机由 add-execution-plan-authorization 定义，本提案只定义审计侧引用与被拒尝试的可区分记录契约）。
- 对抗本机管理员的完整性保证（本地证据对整库替换、尾部截断与旧备份回滚只能给出可检测条件与「不可验证」状态，见 design.md）。

## 双端影响（macOS / iPadOS）

- 审计记录、连续性校验、脱敏、阻断闸门全部位于 `crates/panda-core`，双端行为完全一致；Swift 侧仅 UI/平台服务差异，不引入业务分支 `#if os()`。
- 存储路径差异：macOS `~/.panda-ssh/audit/`，iPadOS App Group 容器内 `audit/`（沿用 `init_store` 注入的 store 根）。
- 审计历史与缺段报告视图为双端共享 SwiftUI 页面；macOS 以窗口/标签承载，iPadOS 以侧栏入口承载，仅导航容器差异。
- 审计写入失败阻断的用户提示双端一致呈现；不涉及定时、后台执行等平台差异能力。
