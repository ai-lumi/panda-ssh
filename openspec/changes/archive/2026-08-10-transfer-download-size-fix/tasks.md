## 1. FFI 侧

- [x] 1.1 `start_transfer` 新增 `size: u64` 参数，下载直接使用，上传 size==0 时本地计算。
- [x] 1.2 `transfer_retry` 重试时传入原任务大小。
- [x] 1.3 更新 `crates/panda-ffi/tests/ffi_fake_server.rs` 所有调用点。

## 2. Swift 侧

- [x] 2.1 `TransferSource.enqueueTransfer` 新增 `size: UInt64`。
- [x] 2.2 `FFITransferSource.enqueueTransfer` 透传 size。
- [x] 2.3 `MockTransferSource.enqueueTransfer` 直接使用 size，移除 `setSize`。
- [x] 2.4 `TransferStore.add` 将 size 传给 source。
- [x] 2.5 `TransferSourceSpy` 增加 size 断言。

## 3. 验证

- [x] 3.1 `cargo test` 全绿。
- [x] 3.2 `build-rust.sh` → `xcodegen` → `xcodebuild -scheme PandaSSH-macOS test` 通过（161 tests）。

## 4. 归档

- [ ] 4.1 `openspec validate transfer-download-size-fix --strict` 通过。
- [ ] 4.2 归档本变更。
