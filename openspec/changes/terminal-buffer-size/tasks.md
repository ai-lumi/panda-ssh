## 1. 测试任务

- [ ] 1.1 编写缓冲区配置持久化测试：验证 `UserDefaults` 读写 `terminalBufferLines` 正常；验证默认值 10000；验证非法值（500、200000）被过滤。
- [ ] 1.2 编写内存估算测试：验证 10000 行估算值在合理范围；验证 1000 行与 100000 行边界值计算正确；验证公式使用 160 列 × Cell 大小。
- [ ] 1.3 编写终端初始化测试：验证新终端标签页读取当前配置并应用；验证配置变更后旧标签页不受影响；验证无效配置回退到默认值 10000。

## 2. 核心实现

- [ ] 2.1 实现 `TerminalSettings`（Swift）：封装 `UserDefaults` 读写 `terminalBufferLines`，提供默认值 10000、校验范围 1000–100000、以及内存估算方法 `estimatedMemoryBytes(forLines:)`。
- [ ] 2.2 修改终端初始化路径：在创建 `TerminalView`/`Terminal` 时读取 `TerminalSettings.bufferLines` 并传入 SwiftTerm 的初始化选项（如 `scrollback`）。
- [ ] 2.3 在 `SettingsView` 新增「终端缓冲区」Section：含行数输入框（macOS Stepper + TextField，iPadOS TextField + NumberPad）、范围校验、内存估算实时显示。

## 3. 集成与验证

- [ ] 3.1 验证设置页修改行数后 `UserDefaults` 正确持久化，重启 App 后值不变。
- [ ] 3.2 验证新打开终端标签页的缓冲区大小与设置一致；验证旧标签页保持原有大小。
- [ ] 3.3 验证 `xcodebuild` macOS/iOS 双端构建通过；验证 `openspec validate terminal-buffer-size --strict` 通过。
