## 验收记录

### 目标尺寸与视觉矩阵

| 平台/状态 | 浅色 | 深色 | 提高对比度 | Dynamic Type | 当前结果 |
| --- | --- | --- | --- | --- | --- |
| Mac 常规窗口 1180×760 | 已构建并实窗截图 | 已完成实窗截图 | 待 Accessibility Inspector 人工复核 | 系统文字样式 | 应用标题已隐藏；空页签 principal 残留已修正并复验 |
| iPad 横屏 1024×768 | 已完成模拟器截图 | 可随系统语义色切换 | 待 Accessibility Inspector 人工复核 | 系统文字样式 | 常规侧栏、SFTP 双栏、传输 inspector 策略已接入 |
| iPad 紧凑分屏 520×768 | 已建立 Preview | 可随系统语义色切换 | 待实机/模拟器人工复核 | 已建立 accessibility2 Preview | 侧栏系统折叠、SFTP 单栏分段、传输 sheet 与 44pt 触控指标已接入 |

异常状态 Preview 使用 MockBackend 的密钥不匹配主机；连接失败和未知主机密钥继续复用既有门控视图及测试。

### 实窗检查

- Mac 最终实窗截图：`assets/panda-ssh-macos-titlebar-final.png`。
- iPad 常规竖屏截图：`assets/panda-ssh-ipad-regular.png`；横屏截图：`assets/panda-ssh-ipad-landscape-oriented.png`。
- 已确认系统红绿灯、系统工具栏、浮动侧栏、窗口圆角均由系统保留，标题区不显示「Panda SSH」。
- 首次截图发现零标签时 principal 仍出现空滚动胶囊，已改为仅在存在标签时创建 principal toolbar item；最终实窗截图确认空胶囊已消失。
- 内容区不再绘制第二条 macOS 页签栏；「代码片段」不再显示「规划中」。
- `box` 主机详情已完成实窗检查；尝试打开终端采集有页签截图时两个 macOS 调试进程退出，未生成新的系统崩溃报告，因此“有页签实窗截图”仍保留为未完成验收项，不以策略测试替代人工结论。

### 自动验证

- OpenSpec strict validation：通过。
- 标准构建顺序：`apple/Scripts/build-rust.sh` → `xcodegen generate --spec project.yml` → macOS/iPadOS `xcodebuild` 已完成；重建后的 xcframework 使用 ARM64 iPad Simulator slice 通过链接。
- macOS XCTest：400 项通过，0 失败；带覆盖率的最终结果位于 `Test-PandaSSH-macOS-2026.08.23_21-01-30-+0800.xcresult`。
- iPad Simulator XCTest：364 项通过，0 失败；最终结果位于 `Test-PandaSSH-iOS-2026.08.23_20-58-35-+0800.xcresult`。
- `cargo test`：通过；需要真实外部 SSH 服务的 4 项按既有配置忽略。
- Rust 覆盖率门禁：通过，lines 95.99%、regions 95.00%。
- Swift 覆盖率：`PandaSSH-macOS.app` 40.42%（5308/13132），未达到 change 任务要求的 95%；测试 target 为 95.90%（7160/7466）。因此任务 8.1 与 change 归档不得标记完成。

### 无障碍检查

- 主机状态新增非颜色 accessibility value。
- 页签新增标题、会话类型/主机密钥状态、选中 trait 与具名关闭操作。
- iPad 当前页签关闭入口和 SFTP 文件行使用不小于 44pt 的触控指标。
- SFTP「本地 / 远程」分段新增辅助功能标签。
- Accessibility Inspector / VoiceOver 的最终焦点顺序人工检查尚未完成，因此任务 7.3 保持未完成。
