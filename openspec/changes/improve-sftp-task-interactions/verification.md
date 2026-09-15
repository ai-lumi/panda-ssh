# 实施记录（2026-09-10）

本次由 `/openspec-apply-change improve-sftp-task-interactions` 明确启动实施。保留工作区已有改动，以本次调用前的文件快照比较增量。

## 基线

- 差异清单、暂存/未暂存补丁及源码备份：`/var/folders/zk/nl1cspjj2dlck9lg43s125v40000gn/T/panda-sftp-interactions-oau0tynj/`。
- Rust：`CARGO_NET_OFFLINE=true cargo test --workspace`，474 项通过，4 项既有忽略。沙箱内首次运行因禁止绑定 loopback 端口失败；经工具审批后以本机 fake SSH 重跑通过。日志：`/private/tmp/panda-sftp-baseline-rust-unrestricted.log`。
- Swift：Xcode 26.6，使用既有缓存 `build-for-testing`。App 源码与现有生成绑定编译通过；测试 target 编译失败，认证测试仍调用 `CredentialResolver(readSecret:)`，文件栏测试仍调用不存在的 `TransferStore.listBatchTransfers()`。日志：`/private/tmp/panda-sftp-baseline-swift-cached.log`。未将该基线视为全绿。
- 生成绑定包含当前凭据、工作区和聚合接口；App 编译未报告缺失 FFI 符号。此证据不等同于双端完整构建或运行时契约验证。
- CLI context 的系统钥匙串说明已过时，遵循当前 AGENTS.md 的凭据文件约定。

## 已审查边界

- 复用当前 Rust 分组与目录上传批量路由。
- 保留凭据、速度、工作区迁移现状；新摘要与删除不得将 Delete 映射为 Upload。
- 退出默认值遵循提案：无任务时 3 秒内两次独立 Command+Q；有未完成任务时显式审查，重复快捷键不得绕过。
- 测试只用隔离 fixture，未删除用户文件，未启动或结束用户使用中的 App。

## 刷新批次

## 退出策略修订（2026-09-15）

本文件先前记录的「3 秒二次确认 + 未完成任务审查」仅代表当时的待实施设计，已被用户确认的统一策略取代：`add-tab-close-and-quit-shortcuts` 定义 2 秒内第二次 CMD+Q 直接启动应用停机，不显示任务审查。SFTP 任务必须停止新登记、协作取消并释放独立连接；远端结果未知时不重放、不伪报成功。后续验证以本提案更新后的 tasks 与 `quit-protection` delta 为准。

已知影响闭包：单文件进度回调、批量创建/扫描/进度/等待决策/终态、TransferSource 修订协议、TransferStore 的主动刷新和定时刷新、注入源与 XCTest。传输调度、分组和暂停语义保持；修订通知允许增加。独立 Swift fixture 直接编译生产 TransferStore 与当前生成绑定，仅用无副作用日志替身，不能替代完整 target 门禁。
