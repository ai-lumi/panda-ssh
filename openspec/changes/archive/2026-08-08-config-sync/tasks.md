## 1. 同步抽象与冲突（Swift）

- [x] 1.1 先写测试：`KVStore` 协议 + 内存 fake 的 set/get/data/synchronize 行为（模拟双端）。
- [x] 1.2 先写测试：快照组装/解析（version + updatedAt + hosts + groups）与旧 key `panda-ssh.hosts.toml` 迁移。
- [x] 1.3 实现 `ConfigSync`：快照 push/pull、`updatedAt` 判定 last-write-wins、远端变更应用（落盘 + 刷新 UI 回调）。
- [x] 1.4 实现 `NSUbiquitousKeyValueStore` 适配与启动时同步。
- [x] 1.5 先写测试：冲突场景（时间戳新旧）与时间戳相等时本地方案优先。
- [x] 1.6 先写测试：应用远端快照落盘时抑制本地 push（防回环）；`key_path` 不被远端快照覆盖（保留本机值）；快照不携带 known_hosts 信任记录。
- [x] 1.7 实现防回环抑制标志与 `key_path` 本机保留逻辑。

## 2. 接入配置变更点（Swift UI）

- [x] 2.1 先写测试：保存主机/分组成功后触发 push 快照。
- [x] 2.2 实现保存后主动推送；收到远端变更后更新本地 TOML 并刷新主机/分组列表。
- [x] 2.3 确保同步快照不含密钥材料（仅 `*_ref` 引用），补充断言测试。
- [x] 2.4 本机未设置私钥的密钥认证主机连接报错并引导选择私钥（与 `authentication` 的 KeyPicker 衔接）。

## 3. 验证

- [x] 3.1 `cargo test` 全绿（核心无改动则回归）。
- [x] 3.2 macOS 构建通过。
- [ ] 3.3 手工验证（需开发者账号 + iCloud 登录）：一端新增主机/分组，另一端自动出现；离线修改后联网收敛；iCloud 未登录时本地功能正常；Mac 已信任的主机在 iPad 首次连接仍需确认指纹。
- [x] 3.4 `openspec validate config-sync --strict` 通过；归档前确认对主 spec `config-sync` 的 MODIFIED delta 与实现一致。

## 4. 质量门禁

- [x] 4.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 4.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。
