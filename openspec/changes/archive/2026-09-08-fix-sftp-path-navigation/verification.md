# 验证记录（2026-09-08）

## 测试先行

- Rust 路径契约测试先因缺少 `panda_core::sftp_path` 失败，实现后通过。
- Swift 回归先复现：失败进入改变路径、尾斜杠无法列举、home 外面包屑缺失、根目录仍可向上、观察通知未转发、扫描期间改变上传目标。
- 并发测试最初暴露测试数据源未隔离的字典竞争；测试替身明确放到主线程后，用受控 continuation 验证请求顺序，不依赖调度巧合。
- 最终审阅补充自动刷新与目录跳转竞争测试，先观察三个断言失败，再实现加载期间不重复刷新；双端回归均通过。

## Verification：结果满足检查与契约

| 检查 | 结果 |
| --- | --- |
| `cargo test` | 通过；需要真实 SSH 服务器的 4 个用例按原有配置忽略 |
| `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` | 通过；lines 96.41%，regions 95.03%；新增核心路径模块两项均为 100% |
| `apple/Scripts/build-rust.sh` → `xcodegen` | 通过；四架构 Rust 库、xcframework、Swift 绑定和 C 头已更新 |
| macOS 构建及 SFTP 定向测试 | 通过 123 项：导航 71、显示状态 6、传输 46 |
| iPadOS 模拟器构建及同组测试 | 通过 123 项；iPad Pro 11-inch (M5)，iOS 26.5 |
| OpenSpec 提案、workspace 和 sftp-transfer 规范严格校验 | 通过 |
| 本次手写源码差异检查、新增 Rust 文件 rustfmt 检查 | 通过；生成 C 头保留 UniFFI 的原始空白格式 |

## 完整检查的独立限制

- 完整 macOS Swift 测试已执行，但 `TabBarLayoutProbeTests` 的工作区/终端布局场景因缺少 `MacOSWorkspaceChromeMetrics` 环境对象崩溃。涉及工作区已有标题栏改动，不属于本次 SFTP 修复；未修改这些实现和测试，也未把全量测试标记为通过。
- Linux `cargo check --target x86_64-unknown-linux-gnu` 无法完成：环境缺少 `x86_64-linux-gnu-gcc`。未安装工具链或新增依赖。
- 没有提交或发布。完整 Swift 测试恢复通过前仍不能满足仓库提交门禁。

## Validation：是否解决用户问题

模拟数据和本机假服务器测试验证了：输入绝对路径后列表与地址同步、非法输入保留目录、失败保留选择、根路径与中文空格名称拼接、双端传输使用当前目录，以及扫描期间目标不漂移。

没有连接用户的真实服务器，没有执行真实远程上传/下载，也没有截取用户屏幕；真实服务器权限、网络条件及最终界面观感仍需用户实际使用验收。

## 影响映射收尾

- 核心与批量路径规则、FFI 和生成边界：已用核心测试、FFI 契约测试及双端构建验证。
- 导航快照、过期请求保护、面板观察、上传目标快照：已用双端定向测试验证。
- 认证、覆盖确认、连接所有权和释放：实现保留；Rust 全量和相关 Swift 传输回归通过。
- 标题栏及其他用户已有改动：未覆盖；其全量测试故障如上记录。
- 规范只同步本变更的路径导航及传输目录契约，保留其他规范条目。

## 本机验证日志

- `/private/tmp/panda-sftp-path-cargo-test.log`
- `/private/tmp/panda-sftp-path-coverage-final.log`
- `/private/tmp/panda-sftp-path-swift-final.log`
- `/private/tmp/panda-sftp-path-ios-test-final.log`
- `/private/tmp/panda-sftp-path-swift-all.log`
- `/private/tmp/panda-sftp-path-linux-check.log`
- 修改前备份：`/private/tmp/panda-sftp-path-backup-20260907/`
