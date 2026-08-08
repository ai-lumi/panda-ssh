## 1. 主机管理（Rust 核心 + FFI）

- [x] 1.1 先写测试：`TomlConfigStore` 全量 CRUD 与原子写、缺文件返回空列表（现有测试补充边界用例）。
- [x] 1.2 先写测试：FFI `list_hosts`/`save_host`/`delete_host` 的 store 行为与未初始化报错。
- [x] 1.3 核对/补齐 FFI 主机 CRUD 导出，保持同步函数 + 全局 runtime 约定。

## 2. 指纹状态查询与显式接受（Rust 核心 + FFI）

- [x] 2.1 先写测试：`KnownHosts::status(host, port)` 返回 Unknown/Match/Mismatch，Mismatch 含存储与呈现指纹。
- [x] 2.2 实现 `KnownHosts::status` 与指纹格式化（SHA256 冒号分隔）。
- [x] 2.3 先写测试：`KnownHosts::store` 原子写入，重复写入不产生重复条目。
- [x] 2.4 先写测试：Reject 探测流程——以 Reject 连接未知主机返回 `UnknownHostKey` 且携带呈现密钥与指纹；`accept_unknown_host_key` 存储该呈现密钥后 status 变为 Match。
- [x] 2.5 实现 `accept_unknown_host_key(host, port, key)` 存储逻辑（存储探测呈现的密钥，非二次握手获取）。
- [x] 2.6 先写测试：FFI `host_key_status`/`accept_unknown_host_key` 与 store 未初始化、未知主机报错；连接入口 `trust_on_first_use=false` 时对未知主机返回 `UnknownHostKey` 且不落盘。
- [x] 2.7 新增 FFI 导出 `host_key_status`/`accept_unknown_host_key`；既有连接入口（`test_connection`/`sftp_*`）增加 `trust_on_first_use: bool` 参数映射到 AcceptAndStore/Reject。`shell_open` 由 tabbed-workspace 变更引入，其签名按同一约定处理，不在本变更实现。

## 3. Swift UI（macOS/iPadOS 共享源码）

- [x] 3.1 先写测试：首次连接确认对话框状态机（信任/取消/指纹展示），含并发串行化——同一主机多个连接请求只弹一次确认框，结果（信任/取消）广播给所有等待者。
- [x] 3.2 主机管理表单完善（地址/端口/用户名/认证/备注/分组；分组字段依赖 server-groups，未落地时先隐藏）。
- [x] 3.3 首次连接「指纹确认」对话框：展示 SHA256 指纹，信任/取消；实现按主机的等待列表，信任后存储呈现密钥再重连，取消则终止所有等待连接。
- [x] 3.4 主机详情展示已记录指纹；密钥变更时阻断并告警。
- [x] 3.5 更新 AGENTS.md 中 host key 行为描述（改为「UI 确认后接受」）。

## 4. 验证

- [x] 4.1 `cargo test` 全绿。
- [x] 4.2 macOS 构建通过；iPadOS 表单与对话框在紧凑布局可用。
- [x] 4.3 手工验证：首次连接弹指纹确认、信任后重连免确认、伪造密钥被阻断、同主机连续开两个连接只弹一次框。
- [x] 4.4 `openspec validate server-management --strict` 通过；归档前确认 `host-key-verification`/`ffi-bridge` 的 MODIFIED delta 与实现一致。

## 5. 质量门禁

- [x] 5.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 5.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。
