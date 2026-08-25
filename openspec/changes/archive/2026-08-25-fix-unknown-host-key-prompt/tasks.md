## 1. 连接门控回归测试

- [x] 1.1 先编写失败 XCTest：`UnknownHostKey` 不得归类为通用连接失败（意外错误路径）。
- [x] 1.2 先编写失败 XCTest：会话建立阶段收到未知密钥时，门控展示 TOFU 指纹确认（正常流程）。
- [x] 1.3 先编写失败 XCTest：重复收到未知密钥或空呈现密钥时，不自动解锁或发送新的连接尝试（边界条件）。

## 2. 连接门控实现

- [x] 2.1 实现 `UnknownHostKey` 的结构化失败分类和门控回退，复用现有 TOFU 确认流程。
- [x] 2.2 将终端与 SFTP 会话入口接入该回退，保留超时、认证失败和密钥不匹配现有语义。

## 3. 验证

- [x] 3.1 运行相关 macOS XCTest，验证首次确认、异常和边界场景。
- [x] 3.2 运行 macOS/iPadOS 构建与 Rust 覆盖率门禁（lines/regions 均不低于 95%）。
- [x] 3.3 运行 `openspec validate fix-unknown-host-key-prompt --strict`。
