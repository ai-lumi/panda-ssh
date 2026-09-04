## Why

现有工作区仅展示标签页的最近连接结果，连接池也只在复用时做一次惰性存活检测。当 SSH 终端停止响应、无法输入时，用户无法判断底层 TCP Socket、SSH 会话还是 shell 通道已经异常；同时也无法查看每个会话的数据通信情况。

## What Changes

- 新增「连接监控」能力：以每条由 Panda SSH 建立的底层传输连接为单位，展示连接标识、主机地址、建立时间、传输 I/O 状态与错误、累计 Socket 收发字节及瞬时收发速率；内核 TCP 状态仅在平台可用时作为附加字段展示。
- 展示每条 SSH 连接承载的 shell、SFTP 与 exec 通道的生命周期、类型、状态与逻辑 I/O 字节数，并关联到工作区标签页或传输任务（若存在）。
- 独立展示 SSH 会话与 shell/SFTP/exec 通道状态；shell 输入写入失败或远端关闭时立即反馈给用户。新增按需且低频的 SSH 健康检查，以区分 TCP 仍建立但 SSH 已不可用的情形。
- 在 macOS 与 iPadOS 提供统一的连接监控页面；页面只查询内存遥测快照，不建立新连接、不保存终端内容，也不默认把遥测持久化。
- 通过 FFI 暴露结构化遥测快照与健康检查入口；Rust 核心负责计数和会话生命周期事实，Swift 仅负责呈现与刷新调度。

## Non-goals

- 不监控应用外的系统 Socket、其他进程流量或操作系统级网络接口流量。
- 不捕获、不展示或持久化密码、私钥、口令、命令文本、终端输出或文件内容。
- 不提供自动重连、后台持续探测、告警推送、流量限速或历史分析；这些均留待独立变更。
- 不承诺 TCP/IP 线缆级精确字节数或重传字节；首版报告应用在实际 Socket 读写边界可观测的 SSH 加密载荷字节，并明确其统计边界。

## Capabilities

### New Capabilities

- `connection-monitoring`: 应用内 TCP Socket、SSH/通道状态、健康结果与流量遥测的采集、查询和跨平台页面展示。

### Modified Capabilities

- `connection-pool`: 连接池需要维护可查询的连接生命周期与健康状态，且断开或失效时更新遥测。
- `ffi-bridge`: FFI 需要导出无敏感内容的连接遥测快照与按需健康检查接口。
- `workspace`: macOS/iPadOS 工作区需要提供进入连接监控页面的入口，并使标签状态可关联到监控记录。

## Impact

- Rust：`crates/panda-core` 在 Socket 读写边界进行线程安全流量计数，并将传输 I/O、SSH keepalive、shell/SFTP/传输的生命周期作为独立状态来源；不得依赖平台专属 API 才能诊断连接异常。
- FFI：`crates/panda-ffi` 新增同步遥测查询与按需健康检查导出，仍使用全局 tokio runtime。
- SwiftUI：`apple/PandaSSH` 新增监控 Store/页面及 macOS、iPadOS 入口；刷新只读取快照，健康检查由用户显式触发或受控的页面操作触发。
- 测试：增加 Rust 单元/集成测试与 Swift XCTest，覆盖正常、失败和边界情形；最终遵守现有 95% lines/regions 覆盖率门禁。
