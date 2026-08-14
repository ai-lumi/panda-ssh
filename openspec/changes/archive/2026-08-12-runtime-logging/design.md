## Context

Panda SSH 目前没有运行时日志系统。错误通过 Toast（1.8 秒消失）或内联文案展示，用户无法回溯。Swift 侧所有关键路径（连接门控、终端会话、SFTP 操作、传输任务、配置同步、FFI 调用）都在 `@MainActor` 上下文执行，少数后台回调已通过 `DispatchQueue.main` 或 `Task { @MainActor in }` 派发到主线程。Rust 侧的 `tracing` crate 已声明为依赖但未使用，本期不引入 Rust 侧日志桥接。

## Goals / Non-Goals

**Goals:**
- 提供线程安全的日志记录器，任意线程可调用
- 内存环形缓冲区上限 1000 条，驱动 UI 实时展示
- 文件日志带 100MB 轮转，持久保存运行历史
- macOS 独立窗口 + iPadOS 侧栏入口，双端均可查看
- 各模块遵循统一的日志规范，方便排查问题

**Non-Goals:**
- Rust 侧 tracing 桥接（Rust 错误已通过 FFI 枚举传递到 Swift，由 Swift 统一记录）
- 日志搜索/高级过滤
- 远程日志上报
- 日志导出按钮（用户可直接访问文件）

## Decisions

### 1. Logger 为非 @MainActor 的 ObservableObject + 线程安全队列

**选择**：Logger 不标注 `@MainActor`，通过内部 `DispatchQueue` 保证线程安全。`@Published entries` 的更新通过 `DispatchQueue.main.async` 派发到主线程。

**理由**：Logger 需要从任意线程调用（FFI 回调、后台 Task），若标注 `@MainActor` 则调用方必须包装 `Task { @MainActor in }`，侵入性大。用内部队列 + main 派发更简洁。

**替代方案**：标注 `@MainActor`，调用方包装 → 调用点冗余且易遗漏；使用 `Actor` → 与 `ObservableObject` 不兼容，SwiftUI 绑定困难。

### 2. 环形缓冲区用数组 + removeFirst

**选择**：`private(set) var entries: [LogEntry]`，超过 1000 时 `removeFirst()`。

**理由**：1000 条的小数组 `removeFirst()` 是 O(n) 但 n=1000 可忽略不计，实现最简单、可测试性最好。

**替代方案**：自实现环形缓冲区（head/tail 指针）→ 复杂度高、调试困难，收益不明显。

### 3. 文件 I/O 在私有串行队列上执行

**选择**：`private let ioQueue = DispatchQueue(label: "panda-ssh.logger.io")`，所有文件读写在该队列上执行。

**理由**：避免文件 I/O 阻塞主线程；串行队列保证写入顺序与轮转安全。

### 4. 轮转策略：rename + 新建

**选择**：文件达到 100MB 时，将 `panda-ssh.log` 重命名为 `panda-ssh.log.1`（覆盖已有），然后新建 `panda-ssh.log` 继续写入。只保留 1 个备份。

**理由**：实现简单，100MB + 100MB = 200MB 磁盘上限明确。多代备份（.1/.2/.3...）增加复杂度但用户收益低。

**替代方案**：按日期轮转 → 需要管理文件数量和过期清理，复杂度高；多代备份 → 磁盘占用不可控。

### 5. LogEntry 为值类型结构体

**选择**：
```
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let module: String
    let message: String
}
```

**理由**：值类型简化内存管理；`Identifiable` 支持 SwiftUI `ForEach`；`Date` 类型便于格式化。

### 6. macOS 用 WindowGroup scene，iPadOS 用 SidebarPage

**选择**：
- macOS：`WindowGroup("日志", id: "log")` 独立窗口 + 菜单命令（`Command(menu: "Window")` + ⌘⇧L）
- iPadOS：`SidebarPage` 枚举新增 `.logs` case，侧栏底部新增「日志」按钮

**理由**：macOS 多窗口是原生体验；iPadOS 不支持多窗口全屏切换，走侧栏页与现有 snippets/settings 一致。

**替代方案**：macOS 也用侧栏页 → 失去独立窗口优势（可与主窗口并排查看日志）。

### 7. 日志文件路径与 AppPaths 复用

**选择**：在 `AppPaths` 新增 `logsDirectoryURL`，macOS 为 `~/.panda-ssh/logs/`，iPadOS 为 App Group 容器下 `Library/logs/`。

**理由**：与现有配置目录体系一致，不引入新的路径解析逻辑。

### 8. 各模块日志规范

**选择**：为每个模块定义明确的日志记录点与级别，形成可执行的规范文档。

| 模块 | error | warning | info | debug |
|------|-------|---------|------|-------|
| SSH | 连接失败、shell 关闭异常、读循环出错 | — | 连接成功、shell 建立 | FFI 调用参数 |
| SFTP | 连接失败、目录列表失败、文件删除失败、home 目录解析失败 | 覆盖冲突待确认 | 连接成功、home 目录解析成功 | 扫描路径摘要 |
| Transfer | — | 任务失败（.failed）、任务取消（.cancelled） | 任务完成（.done） | 轮询状态 |
| HostKey | — | 密钥变更（HostKeyMismatch）、TOFU 待确认、凭据缺失、私钥未选择 | TOFU 已信任 | 探测结果摘要 |
| Config | iCloud 同步拉取失败、写入异常 | 同步冲突、远端变更应用失败 | 同步成功、配置加载完成 | 快照摘要 |
| FFI | start() 失败、allHosts() 失败、allGroups() 失败 | — | 初始化成功 | 调用入口与返回值摘要 |

**消息格式约定**：消息文本 SHOULD 为中文，以分号分隔上下文信息。示例：
- `连接失败 host=192.168.1.1:22; 原因=认证失败`
- `传输完成 name=deploy.tar.gz; 方向=上传; 大小=18MB`
- `主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…`

**安全过滤**：在 Logger 的便捷方法中不做自动过滤（无法可靠判断参数是否敏感），由调用方确保不传入敏感信息。安全审查在 code review 环节把关。

## Risks / Trade-offs

- **高频日志导致主线程抖动**：每条日志触发 `@Published` 更新和 SwiftUI 重绘。→ 缓冲区上限 1000 条，SwiftUI `List` 虚拟化处理大列表；若极端高频场景出现卡顿，可引入 throttle（0.1s 合并批量更新）。本期不预优化。
- **文件轮转竞态**：轮转期间新日志可能写入正在重命名的文件。→ 串行队列保证轮转与写入互斥；轮转期间日志先入内存缓冲，文件恢复后批量补写。
- **iPadOS 沙盒文件访问**：用户无法直接访问 App Group 容器内文件。→ 日志窗口的「在 Finder 中显示」按钮（macOS）或文件分享（iPadOS）可后续迭代。本期用户可通过 Xcode/文件 App 的 App Group 浏览访问。
- **敏感信息泄露风险**：调用方可能不小心传入密码/口令。→ Logger 便捷方法签名只接受 `String` 消息，不接受凭据参数；code review 检查日志调用点不含凭据变量。
|------|-------|---------|------|-------|
| SSH | 连接失败、shell 关闭异常、读循环出错 | — | 连接成功、shell 建立 | FFI 调用参数 |
| SFTP | 连接失败、目录列表失败、文件删除失败、home 目录解析失败 | 覆盖冲突待确认 | 连接成功、home 目录解析成功 | 扫描路径摘要 |
| Transfer | — | 任务失败（.failed）、任务取消（.cancelled） | 任务完成（.done） | 轮询状态 |
| HostKey | — | 密钥变更（HostKeyMismatch）、TOFU 待确认、凭据缺失、私钥未选择 | TOFU 已信任 | 探测结果摘要 |
| Config | iCloud 同步拉取失败、写入异常 | 同步冲突、远端变更应用失败 | 同步成功、配置加载完成 | 快照摘要 |
| FFI | start() 失败、allHosts() 失败、allGroups() 失败 | — | 初始化成功 | 调用入口与返回值摘要 |

**消息格式约定**：消息文本 SHOULD 为中文，以分号分隔上下文信息。示例：
- `连接失败 host=192.168.1.1:22; 原因=认证失败`
- `传输完成 name=deploy.tar.gz; 方向=上传; 大小=18MB`
- `主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…`

**安全过滤**：在 Logger 的便捷方法中不做自动过滤（无法可靠判断参数是否敏感），由调用方确保不传入敏感信息。安全审查在 code review 环节把关。

## Risks / Trade-offs

- **高频日志导致主线程抖动**：每条日志触发 `@Published` 更新和 SwiftUI 重绘。→ 缓冲区上限 1000 条，SwiftUI `List` 虚拟化处理大列表；若极端高频场景出现卡顿，可引入 throttle（0.1s 合并批量更新）。本期不预优化。
- **文件轮转竞态**：轮转期间新日志可能写入正在重命名的文件。→ 串行队列保证轮转与写入互斥；轮转期间日志先入内存缓冲，文件恢复后批量补写。
- **iPadOS 沙盒文件访问**：用户无法直接访问 App Group 容器内文件。→ 日志窗口的「在 Finder 中显示」按钮（macOS）或文件分享（iPadOS）可后续迭代。本期用户可通过 Xcode/文件 App 的 App Group 浏览访问。
|------|-------|---------|------|-------|
| SSH | 连接失败、shell 关闭异常、读循环出错 | — | 连接成功、shell 建立 | FFI 调用参数 |
| SFTP | 连接失败、目录列表失败、文件删除失败、home 目录解析失败 | 覆盖冲突待确认 | 连接成功、home 目录解析成功 | 扫描路径摘要 |
| Transfer | — | 任务失败（.failed）、任务取消（.cancelled） | 任务完成（.done） | 轮询状态 |
| HostKey | — | 密钥变更（HostKeyMismatch）、TOFU 待确认、凭据缺失、私钥未选择 | TOFU 已信任 | 探测结果摘要 |
| Config | iCloud 同步拉取失败、写入异常 | 同步冲突、远端变更应用失败 | 同步成功、配置加载完成 | 快照摘要 |
| FFI | start() 失败、allHosts() 失败、allGroups() 失败 | — | 初始化成功 | 调用入口与返回值摘要 |

**消息格式约定**：消息文本 SHOULD 为中文，以分号分隔上下文信息。示例：
- `连接失败 host=192.168.1.1:22; 原因=认证失败`
- `传输完成 name=deploy.tar.gz; 方向=上传; 大小=18MB`
- `主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…`

**安全过滤**：在 Logger 的便捷方法中不做自动过滤（无法可靠判断参数是否敏感），由调用方确保不传入敏感信息。安全审查在 code review 环节把关。

## Risks / Trade-offs

- **高频日志导致主线程抖动**：每条日志触发 `@Published` 更新和 SwiftUI 重绘。→ 缓冲区上限 1000 条，SwiftUI `List` 虚拟化处理大列表；若极端高频场景出现卡顿，可引入 throttle（0.1s 合并批量更新）。本期不预优化。
- **文件轮转竞态**：轮转期间新日志可能写入正在重命名的文件。→ 串行队列保证轮转与写入互斥；轮转期间日志先入内存缓冲，文件恢复后批量补写。
- **iPadOS 沙盒文件访问**：用户无法直接访问 App Group 容器内文件。→ 日志窗口的「在 Finder 中显示」按钮（macOS）或文件分享（iPadOS）可后续迭代。本期用户可通过 Xcode/文件 App 的 App Group 浏览访问。
|------|-------|---------|------|-------|
| SSH | 连接失败、shell 关闭异常、读循环出错 | — | 连接成功、shell 建立 | FFI 调用参数 |
| SFTP | 连接失败、目录列表失败、文件删除失败、home 目录解析失败 | 覆盖冲突待确认 | 连接成功、home 目录解析成功 | 扫描路径摘要 |
| Transfer | — | 任务失败（.failed）、任务取消（.cancelled） | 任务完成（.done） | 轮询状态 |
| HostKey | — | 密钥变更（HostKeyMismatch）、TOFU 待确认、凭据缺失、私钥未选择 | TOFU 已信任 | 探测结果摘要 |
| Config | iCloud 同步拉取失败、写入异常 | 同步冲突、远端变更应用失败 | 同步成功、配置加载完成 | 快照摘要 |
| FFI | start() 失败、allHosts() 失败、allGroups() 失败 | — | 初始化成功 | 调用入口与返回值摘要 |

**消息格式约定**：消息文本 SHOULD 为中文，以分号分隔上下文信息。示例：
- `连接失败 host=192.168.1.1:22; 原因=认证失败`
- `传输完成 name=deploy.tar.gz; 方向=上传; 大小=18MB`
- `主机密钥变更 host=10.0.0.5:22; 已知指纹=SHA256:abc…; 呈现指纹=SHA256:def…`

**安全过滤**：在 Logger 的便捷方法中不做自动过滤（无法可靠判断参数是否敏感），由调用方确保不传入敏感信息。安全审查在 code review 环节把关。

## Risks / Trade-offs

- **高频日志导致主线程抖动**：每条日志触发 `@Published` 更新和 SwiftUI 重绘。→ 缓冲区上限 1000 条，SwiftUI `List` 虚拟化处理大列表；若极端高频场景出现卡顿，可引入 throttle（0.1s 合并批量更新）。本期不预优化。
- **文件轮转竞态**：轮转期间新日志可能写入正在重命名的文件。→ 串行队列保证轮转与写入互斥；轮转期间日志先入内存缓冲，文件恢复后批量补写。
- **iPadOS 沙盒文件访问**：用户无法直接访问 App Group 容器内文件。→ 日志窗口的「在 Finder 中显示」按钮（macOS）或文件分享（iPadOS）可后续迭代。本期用户可通过 Xcode/文件 App 的 App Group 浏览访问。
