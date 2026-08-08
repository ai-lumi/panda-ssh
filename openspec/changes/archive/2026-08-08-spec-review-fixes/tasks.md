# Tasks: spec-review-fixes

## Rust 侧（TDD：先写失败测试）

- [x] R1. hostkey 测试先行：多 keytype 同主机分别 Match、remove 删除、原子写；再实现 `(host, keytype)` 键控存取 + `remove()` + 原子写
- [x] R2. 错误测试先行：`UnknownHostKey` 携带 fingerprint、`HostKeyMismatch` 携带 stored+presented；再改 `panda-core::Error` 与 ssh.rs handler
- [x] R3. exec 超时测试先行（fake server 挂起命令 → Timeout）； 再实现默认 60s 超时
- [x] R4. FFI 导出 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir`
- [x] R5. `PandaError` 结构化分类，映射 core 错误
- [x] R6. 进程内 russh fake server 集成测试基架：连接/密码认证/ 认证失败/exec/sftp list+upload+download

## Swift 侧

- [x] S1. KeychainHelper 去掉显式 access group；entitlements 移 除 keychain-access-groups
- [x] S2. HostEditView 钥匙串写入失败 → 报错并阻止保存
- [x] S3. AppModel.save/delete 后 ConfigSync.push；App 启动 pull + startObserving，远端变更落盘后 reload
- [x] S4. 删除主机级联删除钥匙串条目（password/passphrase ref）

## Specs 与验证

- [x] V1. 更新 5 个受影响 spec（host-config / host-key-verification / ssh-connection / ffi-bridge / config-sync），`openspec validate --strict` 通过
- [x] V2. `cargo test` 全绿；`build-rust.sh`；macOS + iOS 模拟器 xcodebuild 通过
- [ ] V3. 归档本变更（tasks 全部完成后）
