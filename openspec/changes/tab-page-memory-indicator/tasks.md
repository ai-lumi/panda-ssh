## 1. 测试任务

- [ ] 1.1 编写终端内存估算测试：验证已连接终端返回正数估算；验证未连接/连接中终端返回「—」；验证估算公式使用 bufferLines × cols × CellSize。
- [ ] 1.2 编写 SFTP 内存估算测试：验证文件列表条目数 × entrySize + 活跃传输数 × transferOverhead 计算正确；验证未连接 SFTP 返回「—」。
- [ ] 1.3 编写平台交互测试：验证 macOS 悬停 500ms 后 Tooltip 展示内存信息；验证 iPadOS 长按展示 Popover；验证快速点击不触发 Tooltip/Popover。

## 2. 核心实现

- [ ] 2.1 在 `WorkspaceStore` 新增 `memoryEstimate(for tabID: UUID) -> String`：终端标签页通过 `terminalSessions` 获取 `TerminalSessionStore` 并读取 SwiftTerm 缓冲区行数与列数；SFTP 标签页通过新增注册的 `sftpSessions` 获取文件列表与传输任务数。
- [ ] 2.2 为 SFTP 标签页补充注册/注销机制：在 `SftpTabView.onAppear` 中向 `WorkspaceStore` 注册 `SftpSessionStore`，在关闭/消失时注销，与终端标签页机制保持一致。
- [ ] 2.3 修改 `WorkspaceTabItemView`：macOS 使用 `.onHover` + 延迟 500ms 触发 Tooltip（`.help` 或自定义），展示 `workspace.memoryEstimate(for: tab.id)`；iPadOS 在现有 `.contextMenu` 的 preview 或长按手势附加 Popover 中展示内存信息。

## 3. 集成与验证

- [ ] 3.1 验证多标签场景下各标签页内存估算独立且正确；验证切换/关闭标签页后内存信息同步消失。
- [ ] 3.2 验证 `xcodebuild` macOS/iOS 双端构建通过；验证 `openspec validate tab-page-memory-indicator --strict` 通过。
