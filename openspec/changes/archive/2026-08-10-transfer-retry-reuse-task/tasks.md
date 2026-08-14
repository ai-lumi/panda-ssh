# Tasks: 传输失败重试复用原任务

- [x] 更新 OpenSpec `transfers/spec.md`「失败重试」需求，明确重试复用原任务 id。
- [x] Rust `panda-ffi`：`transfer_retry` 改为重置并复用现有任务，不创建新任务。
- [x] Rust FFI 测试：验证重试返回同一 id；非终态任务重试返回错误。
- [x] Swift `TransferStore`：重试时清除 `speedCalculators` 中对应条目。
- [x] 运行 `cargo test` 全绿。
- [x] 运行 `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS test` 全绿。
- [x] 归档 change 并合并 spec delta。
