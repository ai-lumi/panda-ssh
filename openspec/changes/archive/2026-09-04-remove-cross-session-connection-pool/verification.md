# 实施与验证记录

## 变更契约

按终端标签、SFTP 标签和传输任务隔离连接，精确关闭，重试同代次单飞，旧回调不能改变新连接。不改变认证、主机密钥、文件冲突、传输调度和配置持久化规则。自动测试不连接用户的真实主机；人工验收仅在用户批准的 `10.89.102.28:22` 上执行一次 `exit`，不执行其他远端命令。

## 影响图（高风险：并发、生命周期、FFI）

| 依赖组 | 证据与处置 | 验证 | 状态 |
| --- | --- | --- | --- |
| TerminalSessionStore → TerminalTabView / Coordinator → ShellConnection | 修改：在途代次、过期句柄回收、读写回调归属；保留后台握手与凭据门控 | XCTest：重复 connect、关闭中握手、连续重试、旧成功/失败/读循环回调 | 自动测试通过 |
| WorkspaceStore → 标签关闭/主机删除/TransferStore | 修改：删除按主机延迟断开；按标签立即关闭，不依赖视图销毁；保留主机删除取消任务、关闭确认与队列规则 | Workspace XCTest | 自动测试通过 |
| SftpSessionStore → RemoteFilePaneSource → FFI 句柄 | 修改：持久句柄、同标签单飞、取消/关闭防回生；保留传输任务独立凭据 | Store XCTest 与 FFI fake server | 自动测试通过 |
| ssh-connection 规格 → SshSession / ShellSession 生命周期 | 修改：每次请求独立建连、关闭 inactivity timeout、终端结束释放所属 Transport；删除连接池复用与关闭后保留 Transport 的旧契约 | Rust 单元、fake server、真实双终端验收与主规格反向搜索 | 自动测试、真实验收与规格审计通过 |
| Rust SSH → 活动弱注册表 → 遥测/健康检查 | 修改：清理过期弱引用；不复用；空闲不误判；所有者释放唤醒底层 Transport 退出；关闭后的迟到 I/O 只计流量，不得把终态复活为活动 | Rust 单元与 fake server；本地受控服务器及真实主机等待超过 30 秒 | 自动测试与真实验收通过 |
| FFI shell/SFTP/传输 → Rust 所有权 | 修改：精确且幂等关闭、所有终态释放；保留同步导出和全局 runtime | FFI fake server、生成绑定、Linux 检查与 Apple 构建 | 自动测试及跨平台构建检查通过 |
| 遥测/日志 → 监控 Swift 模型 | 修改：所有者和固定结束原因；有界事件队列独立于监控窗口消费；不记录凭据或终端内容；连接建立前不再登记“临时操作”伪所有者 | 遥测、错误类型、日志敏感内容测试；真实日志窗口核对 | 自动测试与真实验收通过 |
| 认证、known_hosts、传输调度和配置 | 仅验证，不改变规则 | 现有 Rust / Swift 回归测试 | 自动测试通过 |

## 门禁

以下为本次最终实现的验证结果，不沿用此前版本的通过记录。

| 检查 | 结果与边界 |
| --- | --- |
| `openspec validate remove-cross-session-connection-pool --strict` | 通过 |
| 归档后九个主规格逐项 `--strict` 校验与 delta 反向比较 | 全部通过；ADDED/MODIFIED 内容一致，REMOVED 要求均已不存在 |
| 归档后 `openspec validate --all --strict` | 本变更涉及的全部规格通过；全仓汇总为 38 通过、1 失败，唯一失败是未纳入本任务的既有活动提案 `fix-tab-close-hit-target` 缺少有效 delta |
| `cargo fmt --all --check`、`git diff --check` | 通过；生成后的 C 头文件已清除尾随空格 |
| `cargo test --workspace --offline` | 全绿；包含核心单元 121 项、核心 fake server 71 项（含实际等待 32 秒的隔离回归）、FFI 单元 6 项、FFI fake server 62 项及其余集成/文档测试；4 项会执行其他远端命令的真实服务器测试按定义保持 ignored，本次未运行 |
| `cargo llvm-cov --workspace --tests --offline --fail-under-lines 95 --fail-under-regions 95` | 退出码 0；lines **96.44%**（5202 行、未覆盖 185），regions **95.04%**（9007 区域、未覆盖 447），functions **95.06%**。这是工作区汇总门禁，不代表每个文件或所有分支均达到 95% |
| macOS XCTest | 最终完整回归 **450 / 450 通过**，0 失败、0 跳过 |
| `CARGO_NET_OFFLINE=true apple/Scripts/build-rust.sh` → `xcodegen` → macOS / iPadOS 设备构建 | 全部通过；设备构建使用 `CODE_SIGNING_ALLOWED=NO`，不包含签名、安装或真机运行验证 |
| iPadOS ARM64 模拟器构建 | 通过；使用 `ARCHS=arm64`。不限制架构的通用模拟器构建因现有 xcframework 缺少 x86_64 模拟器切片失败，不能宣称 Intel 模拟器通过 |
| `cargo check --workspace --offline --target x86_64-unknown-linux-gnu` | 通过；使用 v15.2.0 临时交叉 GCC，下载包 SHA-256 `04746819d162f829dacf2ea6d6947b9fb4141ffbd91588f0bfbaab4c2c7e1a30` 与上游 Homebrew 公式一致；未写入系统工具链目录 |
| 同主机真实交互、监控/日志人工验收 | **通过**。在 `10.89.102.28:22` 建立两个终端，监控显示 Session #1 / 终端 #2 与 Session #3 / 终端 #4 为两个独立 Socket；只在第二个终端执行一次 `exit` 后 Session #3 立即移除，Session #1 保持健康；只单击一次重试后仅新增 Session #5 / 终端 #6；静置 35 秒后两者仍为“Socket 空闲（正常）/SSH 已认证/探测健康”。未执行任何其他远端命令 |
| 真实生命周期日志 | **通过**。`exit` 连接依次记录“Channel 正常结束”“显式关闭”“所有者释放”，没有后续“SSH 传输异常”；重试只记录一次；三个连接均只使用“终端标签”所有者，不再产生“临时操作”重复归属 |
| 主规格合并与变更归档 | 九个 capability delta 已逐条合并并反向比较一致，`connection-pool` Purpose 已改为显式所有权语义；审计额外捕获并修正了 `ssh-connection` 与 `ffi-bridge` 的旧复用契约；已归档到 `openspec/changes/archive/2026-09-04-remove-cross-session-connection-pool/` |

最终完整 XCTest 结果包：`/private/tmp/panda-ssh-lifecycle.Q2z2Qi/final-post-validation-mac-tests.xcresult`，使用 `xcresulttool get test-results summary` 核实测试计数。

Homebrew tap 因 GitHub HTTP/2 framing 错误连续失败，未安装公式，也未修改全局 Git 或 shell 配置。随后改用已校验的临时 Release 包完成 Linux 检查；下载包和解压目录仍位于 `/private/tmp/x86_64-unknown-linux-gnu-aarch64-darwin-v15.2.0.tar.gz` 与 `/private/tmp/x86_64-unknown-linux-gnu`，可在不再需要复核证据时清理。

构建仍有警告，包括配置归档指针、未使用值、测试代码并发捕获及静态库部署版本警告；本次不宣称无警告，也不把构建成功等同于低版本设备运行验证。

## 关键回归与 TDD 证据

本次先观察下列新增测试在修复前失败，再实现并重跑至通过：

- 终端重复建连、关闭期间握手晚到、旧成功/失败/读循环回调污染新代次；SFTP 同标签并发握手及关闭后晚到的句柄回收。
- 工作区标签关闭立即释放对应会话，不能仅依赖 `onDisappear`。
- 已丢弃 `SshSession` 的存活 SFTP 通道不得继续持有可通信 Socket；使用所有者生命周期通知唤醒底层读取退出。
- 终端输入队列已满时仍可关闭；空输入是无操作，不再作为内部关闭哨兵。
- 正常 shell 结束以结构化 `ShellSessionClosed` 返回；Transport 故障的读、写和 resize 不得伪装为正常结束。
- 并发重复关闭同一终端句柄幂等；已关闭连接的后续 EOF 不误报异常；清理故障连接不覆盖原来的失败状态。
- 已关闭 Transport 的迟到 disconnect 帧写入仍计入流量，但不能把 Closed/Failed 终态改回 Active，也不能触发伪造的传输异常；该回归测试在修复前观察到 Failed、修复后保持 Closed。
- 连接生命周期日志使用固定原因枚举，有界保留并可在连接释放后读取；Swift 不把原始连接错误或敏感内容写入日志。
- FFI 连接建立只在实际所有者已知时登记所有者：终端为“终端标签”，SFTP 兼容入口为“SFTP 操作”；fake-server 测试在修复前捕获到“临时操作 + 终端标签”双成功事件，修复后每条连接只有实际所有者。

`independent_shells_survive_exit_retry_and_idle_past_thirty_seconds` 已通过：并发建立同一地址的两个独立连接，一个 shell 退出后建立新的重试连接，实际等待超过 32 秒，另一个原连接和重试连接仍可回显数据，健康状态均正常。这验证了本地受控服务器下的隔离与超时回归，尚不能证明所有真实网络环境均不存在断连。

## 人工验收边界与剩余归档步骤

人工验收遵守用户限制，只执行 `exit`，因此没有通过输入其他命令证明终端交互回显，也没有在真实主机执行 SFTP 读写或后台传输；这些路径由 fake server、Swift 状态机测试和双平台构建覆盖。监控状态、连接数量、终端结束提示、35 秒存活和生命周期日志均在最终重建的 macOS App 中直接观察。

九个 capability delta 已合并回主规格并逐条反向比较一致，`connection-pool` Purpose 已更新。首次归档前审计发现 `ssh-connection` 和 `ffi-bridge` 仍有旧连接池语义，随即撤回归档、补齐 delta 与主规格并重新校验。全部 **18 / 18** 任务完成并已归档；归档后九个目标规格严格校验、delta 反向比较、Rust 格式检查、差异空白检查、旧符号搜索与仓库状态审计均已执行。全仓 OpenSpec 校验另有一个不属于本变更的既有活动提案 `fix-tab-close-hit-target` 缺少有效 delta，作为独立问题记录，不在本变更中越权修改。
