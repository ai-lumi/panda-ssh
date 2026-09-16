# 验证记录：refactor-ffi-module-boundaries

## 1.3 覆盖率基线（`--no-cfg-coverage` 分组）

依据 design 决策 4：`cfg(coverage)` 会阻塞 FFI fake-server 测试，门禁与基线统一使用
`--no-cfg-coverage`；core 与 FFI 测试目标分组采集，全部完成后一次性出报告。

### 基线命令（cargo-llvm-cov 0.8.7 / rustc 1.93.0，在仓库根目录执行）

```sh
# 分组 1：panda-core 全部测试目标（lib 单元测试 + 集成测试；real_server 默认 --ignored 不参与）
cargo llvm-cov --no-cfg-coverage --no-report --package panda-core --tests

# 分组 2：panda-ffi 全部测试目标（lib 单元测试 + 9 个集成测试，含 ffi_fake_server）
cargo llvm-cov --no-cfg-coverage --no-report --package panda-ffi --lib --tests

# 合并报告（profraw 在 target/llvm-cov-target/ 下跨组累积；--no-run 不再执行测试）
cargo llvm-cov --no-cfg-coverage --no-run --workspace --tests --summary-only
```

说明：`--no-run` 在 0.8.7 可用（有 deprecation 警告，新版本等价写法为
`cargo llvm-cov report` 子命令）；两组之间不清理 profraw，实现按组累积。

### 基线数值（2026-09-16，分组采集合并报告）

| 指标 | 总量 | 覆盖率 |
| --- | --- | --- |
| Lines | 10030（missed 304） | 96.97% |
| Regions | 18258（missed 747） | 95.91% |

业务 FFI 模块（必须计入门禁）单项数据：

| 模块 | Lines | Regions |
| --- | --- | --- |
| ffi_sessions.rs | 97.08% | 90.85% |
| ffi_store.rs | 96.97% | 92.95% |
| ffi_telemetry.rs | 99.26% | 99.09% |
| ffi_transfers.rs | 97.89% | 97.06% |
| ffi_workspace.rs | 98.72% | 98.48% |
| ffi_adapter.rs（唯一允许排除） | 100.00% | 100.00% |

## 3.4 覆盖率门禁（文件级仅排除 ffi_adapter）

```sh
# 分组 1：采集 panda-core profile
cargo llvm-cov --no-cfg-coverage --no-report --package panda-core --tests

# 分组 2：采集 panda-ffi profile（含 ffi_fake_server）
cargo llvm-cov --no-cfg-coverage --no-report --package panda-ffi --lib --tests

# 合并并判定门禁；不重新运行测试
cargo llvm-cov --no-cfg-coverage --no-run --workspace --tests \
  --ignore-filename-regex 'ffi_adapter' \
  --fail-under-lines 95 --fail-under-regions 95
```

- 排除正则只匹配 `crates/panda-ffi/src/ffi_adapter.rs`（无状态纯值适配器，18 行）。
- 会话、传输、TOFU、持久化、日志、遥测、工作区与终端状态机所在模块全部纳入统计。
- 单次 `--workspace --tests` 运行不能替代上述分组：在本机复验中它未汇入 FFI profile，
  产生 lines 61.28%、regions 62.34% 的无效汇总。
- 复验结果（2026-09-16）：**通过（exit 0）**。TOTAL lines 96.99%（missed 302/10024）、
  regions 95.92%（missed 745/18248），`ffi_adapter.rs` 不再出现在报告中，
  全部业务 FFI 模块均在统计内。

## 3.3 UniFFI 绑定与 Swift 兼容

```sh
apple/Scripts/build-rust.sh
```

- 验证多架构静态库 + xcframework 构建成功、UniFFI 绑定重新生成。
- 兼容性验证方式：拆分前备份 `apple/Rust/Generated/`，构建后 diff，确认生成的
  Swift API（导出名称、参数、返回类型）与拆分前完全一致。
- 结果：待执行后填写。

### 执行结果（2026-09-16）

1. **构建**：`build-rust.sh` 通过——4 个目标（aarch64/x86_64 darwin、
   aarch64-ios、aarch64-ios-sim）release 编译成功，xcframework 重建，
   uniffi-bindgen 从 macOS dylib 重新生成绑定。
2. **绑定层兼容性**（构建前备份 `apple/Rust/Generated` 至
   `/tmp/panda-generated-before-refactor-20260916`，构建后归一化对比）：
   - `public func` 声明行（名称 + 参数 + 返回类型）排序后 diff：**完全一致**；
   - `public struct/enum/class/protocol/typealias` 声明排序后 diff：**完全一致**；
   - 枚举 `case` 行排序后 diff：**完全一致**；
   - `panda_ffiFFI.h` 剔除注释后声明排序 diff：**完全一致**。
   原始文件 diff 仅含两类无害差异：函数排列顺序（旧 lib.rs 字母序 → 新版按
   模块分组序，Swift 不依赖文件内顺序）与个别文档注释在拆分迁移时被精简。
3. **macOS 端**：`xcodegen` 重新生成工程后
   `xcodebuild -scheme PandaSSH-macOS build` **BUILD SUCCEEDED**（首次失败为
   DerivedData 中残留的旧 build-for-testing 未签名 xctest 插件导致 CodeSign
   失败，`clean` 后通过，与代码无关）。
4. **iOS 端**：`xcodebuild -scheme PandaSSH-iOS build` 失败于
   `apple/PandaSSH/Workspace/UnifiedWorkspaceTabStrip.swift:327`
   （ViewBuilder 闭包含控制流语句）。该行来自另一在途变更
   `add-tab-close-and-quit-shortcuts` 的未提交修改（git diff hunk
   `@@ -249,6 +316,27 @@` 新增），**与本次 FFI 重构无关**——本变更未改任何
   Swift 调用点，且绑定归一化 diff 与 macOS 全量编译已证明 API 兼容。该错误
   需在 add-tab-close-and-quit-shortcuts 变更范围内修复。

### 复验结果（2026-09-16）

1. `cargo test --workspace` 全绿；运行 fake-server 测试需允许本地回环端口监听。
2. 重新执行 `build-rust.sh` 与 `xcodegen` 后，macOS `xcodebuild` **BUILD SUCCEEDED**。
3. iOS 默认构建仅因本机未配置 development team 而在签名阶段失败；
   `xcodebuild -scheme PandaSSH-iOS build CODE_SIGNING_ALLOWED=NO` **BUILD SUCCEEDED**，
   已验证当前 Swift 调用与重新生成绑定可编译、链接。
