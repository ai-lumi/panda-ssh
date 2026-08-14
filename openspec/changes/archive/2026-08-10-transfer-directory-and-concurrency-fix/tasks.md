## 1. 并发排队状态修正

- [x] 1.1 Rust `run_transfer_task` 先 `acquire` 信号量，再切换为 `Running`。
- [x] 1.2 确保取消对 `Queued` 任务立即生效。

## 2. 目录上传拆分

- [x] 2.1 Swift `uploadSelected` 检测目录并枚举直接文件。
- [x] 2.2 每个文件作为独立上传任务加入队列。
- [x] 2.3 演示/测试模式保持 placeholder 行为。

## 3. 验证

- [x] 3.1 `cargo test` 全绿。
- [x] 3.2 `build-rust.sh` → `xcodegen` → `xcodebuild -scheme PandaSSH-macOS test` 通过（191 tests）。

## 4. 归档

- [ ] 4.1 `openspec validate transfer-directory-and-concurrency-fix --strict` 通过。
- [ ] 4.2 归档本变更。
