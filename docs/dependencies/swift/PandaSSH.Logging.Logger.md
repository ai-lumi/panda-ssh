# `PandaSSH.Logging.Logger`

源文件：`apple/PandaSSH/Logging/Logger.swift`

## 直接依赖

- `Foundation.FileManager` 与 `FileHandle`：文件日志与轮转。
- `Foundation.DispatchQueue`：串行文件 I/O 与主线程 UI 更新。
- `PandaSSH.AppPaths`：日志目录根路径。
- `SwiftUI.ObservableObject`：向日志视图发布内存缓冲区。

## 被依赖方

- `PandaSSH.PandaCoreBackend`、连接与 SFTP 存储层：记录业务和 FFI 错误。
- `PandaSSH.Logging.LogView`：显示日志条目。

## 边界

日志写入失败不能影响业务操作；但失败应保留可观测信号，避免日志系统自身静默失效。

