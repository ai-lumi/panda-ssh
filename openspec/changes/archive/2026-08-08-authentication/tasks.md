## 1. 钥匙串封装（Swift）

- [x] 1.1 先写测试：`KeychainService` 协议 + 内存 fake 的 save/read/delete 行为（不触碰真实钥匙串），条目以扁平键 `host.<id>.password` / `host.<id>.passphrase` 寻址。
- [x] 1.2 实现 `KeychainHelper` 的 `KeychainService` 适配（`kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable`；不设显式 `kSecAttrAccessGroup`，与主 spec「凭据漫游」一致）。
- [x] 1.3 先写测试：凭据解析——按主机认证方式读取 password/passphrase ref，缺失时返回「需手动输入」。
- [x] 1.4 实现凭据解析与连接参数组装。
- [x] 1.5 先写测试：手动输入密码的会话作用域——同一主机多个会话（标签页）各自触发密码输入、互不共享；会话结束后密码被销毁、不写入钥匙串/配置/任何共享存储。
- [x] 1.6 实现按会话独立持有手动输入的密码（挂在会话对象上，关闭即销毁；与 tabbed-workspace 的标签页生命周期对接）。
- [x] 1.7 先写测试：保存失败语义——表单保存路径写入失败阻止保存并报错；登录时保存失败仅提示、本次连接继续且配置不写 ref。

## 2. 认证表单与私钥选择（Swift，macOS/iPadOS 共享源码）

- [x] 2.1 先写测试：`KeyPicker` 协议 + fake（返回固定路径），认证表单「保存密码」开关状态机。
- [x] 2.2 实现密码框与「保存密码」开关（保存→写入钥匙串与 `password_ref`）。
- [x] 2.3 实现 `KeyPicker` 平台分支：macOS `NSOpenPanel`，iPadOS `UIDocumentPicker` + 安全作用域拷贝。
- [x] 2.4 实现密钥认证表单：私钥选择、口令输入与「保存口令」开关。
- [x] 2.5 清除/重新保存已保存凭据的入口。

## 3. 验证

- [x] 3.1 `cargo test` 全绿（核心无改动则回归确认）。
- [x] 3.2 macOS 构建通过；iPadOS 文档选择器流程可用。
- [x] 3.3 手工验证：保存密码后重启 App 自动填充登录；选择私钥后密钥登录成功；配置文件中无明文密钥材料。
- [x] 3.4 `openspec validate authentication --strict` 通过。

## 4. 质量门禁

- [x] 4.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 4.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。
