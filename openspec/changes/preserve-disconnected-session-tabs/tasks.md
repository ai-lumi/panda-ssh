## 1. 提案联动与基线

- [ ] 1.1 评审本提案与 `fix-ssh-session-failure-diagnostics`，确定可复用的安全终态枚举和 SFTP 会话不可用判定；记录任何尚未具备的 FFI 契约，避免双重分类。
- [ ] 1.2 只读复核 `TerminalTabView`、`TerminalSessionStore`、`SftpTabView`、`SftpSessionStore`、`WorkspaceStore` 与现有测试，记录初次失败、已建立后断开、显式关闭的当前状态迁移基线。

## 2. 终端断开后保留上下文（TDD）

- [ ] 2.1 先写 Swift XCTest 失败用例：正常流程覆盖 shell 零退出后保留缓存终端与安全尾注、点击重新连接生成新代次；意外流程覆盖读写/keepalive 故障后保留首个安全原因且输入不可用；边界覆盖未知原因、重复结束、旧代次回调及关闭与断开竞争。记录 red 结果。
- [ ] 2.2 实现最小终端终态呈现：保留终端画布、追加白名单原因与重新连接入口，已建立后终态映射为标签红色；不得使用原始异常字符串。使 2.1 通过后重构。

## 3. SFTP 会话断开状态（TDD）

- [ ] 3.1 先写 Swift XCTest / fake FFI 失败用例：正常流程覆盖初次连接成功后目录快照保留；意外流程覆盖会话级 Transport/句柄失效后标签标红、远程操作被拒绝、其他标签与后台传输不受影响；边界覆盖断开与刷新竞争、重复失效回调及重连时原路径不存在。记录 red 结果。
- [ ] 3.2 如 FFI 尚不能可靠区分会话级失效，先写 Rust/FFI fake 失败测试：正常流程覆盖可用句柄；意外流程覆盖已关闭/Transport 失效句柄；边界覆盖重复关闭与同主机独立句柄。以最小结构化类别或状态查询实现，保持同步导出和全局 runtime。使测试通过。
- [ ] 3.3 实现 SFTP 已建立后断开时的快照保留、红色标签图标、远程操作统一拒绝、断开提示与重新连接；初次连接失败继续使用错误页。使 3.1 通过后重构。

## 4. SFTP 业务错误不误报断开（TDD）

- [ ] 4.1 先写失败用例：权限拒绝、路径不存在、覆盖冲突和单项传输失败仅走既有操作提示，SFTP 标签仍保持可用状态。记录 red 结果。
- [ ] 4.2 在会话边界应用结构化分类，移除任何基于错误字符串的猜测；使 4.1 通过。

## 5. 综合验证

- [ ] 5.1 补跨层失败用例：同主机多个终端/SFTP 标签中一个断开时，红色状态、侧栏聚合、其他会话和后台传输均符合规格；记录 red 结果后完成接线。
- [ ] 5.2 执行相关 Rust 测试、`cargo test` 与 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`；未通过时记录实际失败，不宣称门禁通过。
- [ ] 5.3 若 FFI 改动，按 `apple/Scripts/build-rust.sh` → `cd apple && xcodegen` → macOS/iPadOS `xcodebuild` 执行；运行改动 Swift target 的 XCTest。
- [ ] 5.4 用受控 fake 服务器在 macOS/iPadOS 手动验收：SSH 保留可滚动输出和安全原因，SFTP 保留快照并标红，重连行为、初次失败和单次业务错误均符合规格。
- [ ] 5.5 执行 `openspec validate preserve-disconnected-session-tabs --strict`；实现与验收完成后才将 delta 合并入主规格并归档。
