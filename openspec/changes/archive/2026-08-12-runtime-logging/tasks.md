## 1. LogEntry 与 LogLevel 数据模型

- [x] 1.1 编写 `LogEntryTests`：验证 LogEntry 的 `formatted` 属性包含 ISO8601 时间戳、级别名、模块名和消息文本；验证 LogLevel 四个 case（debug/info/warning/error）各有对应的显示颜色
- [x] 1.2 实现 `LogLevel` 枚举（debug/info/warning/error，带 `color` 计算属性）和 `LogEntry` 结构体（Identifiable，含 timestamp/level/module/message + `formatted` 计算属性）

## 2. Logger 内存环形缓冲区

- [x] 2.1 编写 `LoggerBufferTests`：
  - 正常流程：记录 500 条后 `entries` 包含 500 条，顺序正确
  - 边界条件：记录 1000 条后再记第 1001 条，缓冲区仍为 1000 条且第 1 条被丢弃
  - 意外操作：`clear()` 后 `entries` 为空；clear 不影响后续记录
- [x] 2.2 实现 `Logger` 类（ObservableObject）：内存环形缓冲区上限 1000 条（数组 + removeFirst），`@Published private(set) var entries`，线程安全（内部 DispatchQueue 派发 @Published 更新到 main），`log(_:level:module:)` / `debug` / `info` / `warning` / `error` 便捷方法，`clear()` 清空缓冲区

## 3. Logger 文件日志与轮转

- [x] 3.1 编写 `LoggerFileTests`（使用临时目录注入）：
  - 正常流程：记录日志后文件存在且内容包含格式化条目；重启（重新初始化）后追加不覆盖
  - 边界条件：文件达到 100MB 阈值时触发轮转，`panda-ssh.log` 重命名为 `panda-ssh.log.1`，新日志写入新建的 `panda-ssh.log`；再次轮转覆盖已有 `.1`
  - 意外操作：目录不存在时自动创建；写入失败时不崩溃（静默失败，内存缓冲不受影响）
- [x] 3.2 实现 Logger 文件 I/O：私有串行 `DispatchQueue` 上执行文件追加写入；每次写入前检查文件大小，达到 100MB 时先轮转（rename → .1，覆盖已有）再写入新文件；目录自动创建；`init(configDirectory:)` 接受路径注入用于测试

## 4. UI 日志窗口

- [x] 4.1 实现 `LogView`：SwiftUI `List` 展示 `logger.entries`（每行显示 formatted 文本 + 级别颜色），自动滚动到底部（`ScrollViewReader` + `onChange`），工具栏清除按钮（调用 `logger.clear()`），空状态用 `ContentUnavailableView`
- [x] 4.2 macOS 集成：`PandaSSHApp` 中新增 `WindowGroup("日志", id: "panda-log")` scene 展示 `LogView`；注册菜单命令「窗口 → 日志」+ 快捷键 ⌘⇧L（`CommandGroup`）
- [x] 4.3 iPadOS 集成：`SidebarPage` 枚举新增 `.logs` case；`SidebarView` 底部新增「日志」入口；`HostListView` 主区域 switch 分支新增 `.logs → LogView`

## 5. 关键路径日志接入（遵循 design.md 第 8 节模块规范）

- [x] 5.1 `ConnectionGate`（模块名 `HostKey`）：密钥变更时 warning `主机密钥变更 host=addr:port; 已知指纹=…; 呈现指纹=…`；TOFU 待确认时 warning；凭据缺失时 warning；私钥未选择时 warning；TOFU 已信任后 info `已信任主机密钥 host=addr:port`
- [x] 5.2 `TerminalSessionStore`（模块名 `SSH`）：连接失败时 error `连接失败 host=addr:port; 原因=…`；连接成功后 info `已连接 host=addr:port`；shell 关闭异常时 error
- [x] 5.3 `SftpSessionStore`（模块名 `SFTP`）：连接失败时 error `SFTP 连接失败 host=addr:port; 原因=…`；home 目录解析失败时 error（含兜底说明）；覆盖冲突时 warning `文件覆盖确认 name=…; 源大小=…; 目标大小=…`；连接成功后 info `SFTP 已连接 host=addr:port`
- [x] 5.4 `TransferStore`（模块名 `Transfer`）：任务失败时 warning `传输失败 name=…; 方向=…; 原因=…`；任务取消时 info `传输取消 name=…; 方向=…`；任务完成时 info `传输完成 name=…; 方向=…; 大小=…`
- [x] 5.5 `PandaCoreBackend`（模块名 `FFI`）：`start()` 失败时 error `FFI 初始化失败; 原因=…`；`allHosts()`/`allGroups()` 失败时 error `FFI 调用失败; 方法=…; 原因=…`；初始化成功后 info `FFI 初始化成功`
- [x] 5.6 `ConfigSync`（模块名 `Config`）：iCloud 拉取失败时 error `配置同步失败; 原因=…`；远端变更应用失败时 warning `远端配置应用失败; 原因=…`；同步成功后 info `配置同步完成; 主机数=N`；配置加载完成后 info `配置加载完成; 主机数=N`

## 6. 验证与收尾

- [x] 6.1 运行 `cargo test`（确认 Rust 侧无回归）
- [x] 6.2 运行 macOS XCTest 全量，确认全绿 + 覆盖率 ≥ 95%
- [x] 6.3 运行 `xcodegen` + `xcodebuild` 双端构建通过
