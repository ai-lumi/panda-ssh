# Tasks

## 1. 连接池模块与测试

### 1.1 测试：连接池核心行为
- [x] 1.1.1 正常流程：同一 key 两次获取复用同一会话
- [x] 1.1.2 正常流程：不同 key 获取得到不同会话
- [x] 1.1.3 意外操作：获取后 open_channel 失败时自动重建会话
- [x] 1.1.4 边界条件：池中无条目时获取新建会话
- [x] 1.1.5 边界条件：会话被外部断开（drop）后复用失效

### 1.2 实现：连接池核心结构
- [x] 1.2.1 新增 `panda-core/src/connection_pool.rs`，定义 `PoolKey`、`PoolEntry`
- [x] 1.2.2 实现 `ConnectionPool::get_or_create()`：复用逻辑 + 新建回退
- [x] 1.2.3 实现 `ConnectionPool::put()`：新建会话加入池（内聚在 get_or_create 中）
- [x] 1.2.4 实现 `ConnectionPool::remove()`：失效会话剔除
- [x] 1.2.5 跑 `cargo test` 确认 1.1 的测试全绿

## 2. 空闲超时回收与测试

### 2.1 测试：空闲超时行为
- [x] 2.1.1 正常流程：会话空闲 30 秒后被自动回收
- [x] 2.1.2 意外操作：活跃会话在 30 秒内被使用时不被回收
- [x] 2.1.3 边界条件：超时检查任务在池为空时无副作用
- [x] 2.1.4 边界条件：超时后再次获取同 key 时重建新会话

### 2.2 实现：空闲超时回收
- [x] 2.2.1 在 `ConnectionPool` 中记录 `last_used: Instant`
- [x] 2.2.2 启动后台 tokio task，每 5 秒扫描并关闭超时会话
- [x] 2.2.3 每次获取/归还时更新 `last_used`
- [x] 2.2.4 跑 `cargo test` 确认 2.1 的测试全绿

## 3. 多路频道复用测试与集成

### 3.1 测试：单连接多频道
- [x] 3.1.1 正常流程：同一会话上同时打开 SFTP 频道和 shell 频道
- [x] 3.1.2 正常流程：两个 tokio task 并发获取同一会话，各自拿到独立频道
- [x] 3.1.3 意外操作：某频道错误不影响同连接其他频道
- [x] 3.1.4 边界条件：频道数达到 russh 上限时返回错误（由 russh 内部保证）

### 3.2 实现：频道复用集成
- [x] 3.2.1 修改 `open_sftp_session` 走 `get_or_create_session`
- [x] 3.2.2 修改 `shell_open` 走 `get_or_create_session`
- [x] 3.2.3 修改 `test_connection` 走 `get_or_create_session`
- [x] 3.2.4 验证：在 fake_server 测试中复用会话执行 SFTP + shell
- [x] 3.2.5 跑 `cargo test` 确认全绿

## 4. FFI 层接入与端到端验证

### 4.1 测试：FFI 层透明复用
- [x] 4.1.1 正常流程：FFI `test_connection` 两次调用复用同一会话
- [x] 4.1.2 正常流程：FFI `sftp_list` 连续两次调用复用同一会话
- [x] 4.1.3 意外操作：凭据变更后同 host_id 不再复用旧会话
- [x] 4.1.4 边界条件：连接池在并发 FFI 调用下线程安全

### 4.2 实现：FFI 接入
- [x] 4.2.1 在 `panda-ffi/src/lib.rs` 中新增 `get_or_create_session` 封装
- [x] 4.2.2 替换所有 `connect_host` 调用为 `get_or_create_session`
- [x] 4.2.3 跑 `cargo test` 全绿
- [x] 4.2.4 跑 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`
- [x] 4.2.5 运行 `build-rust.sh` → `xcodebuild` 验证 Swift 侧编译通过

## 5. 归档与 spec 合并

- [x] 5.1 将 `openspec/changes/ssh-connection-pool/specs/` 中的 delta 合并回 `openspec/specs/`
- [x] 5.2 运行 `openspec archive-change ssh-connection-pool`
