## 1. 核心连接语义（TDD）

- [x] 1.1 先补 Rust 失败测试，覆盖已认证连接正常空闲、keepalive 失败、EOF/读写错误与 inactivity timeout 边界，再将 inactivity timeout 关闭并保留有限 keepalive 判失效
- [x] 1.2 先补 Rust 失败测试，覆盖活动连接注册的正常查找、失效弱引用清理、重复关闭和并发边界，再实现只用于遥测/健康检查的弱引用注册表与所有者元数据
- [x] 1.3 先补 Rust 失败测试，覆盖同主机独立连接、一个连接结束不影响另一个及并发建立边界，再移除业务侧全局连接缓存与主机级批量断开

## 2. FFI 显式句柄（TDD）

- [x] 2.1 先补 FFI fake-server 失败测试，覆盖两个终端句柄正常隔离、远端 exit、重复关闭、无效句柄与并发打开，再迁移 shell 打开/读写/关闭到专属 Transport
- [x] 2.2 先补 FFI fake-server 失败测试，覆盖 SFTP 句柄打开/列表/文件操作/关闭、同主机双句柄隔离、无效句柄和空路径边界，再实现持久 SFTP 标签句柄 API
- [x] 2.3 先补单文件与批量传输失败测试，覆盖成功、认证/网络失败、取消和空批次边界，再让每个运行任务建立并在所有终态释放独立连接
- [x] 2.4 删除旧连接池、`disconnect_host` 与工作区使用的无状态 SFTP 路径，重新生成 UniFFI Swift 绑定和 C 头文件并修复契约测试

## 3. Swift 状态机与工作区（TDD）

- [x] 3.1 先补 `TerminalSessionStore` 失败测试，覆盖一次重试、重复生命周期触发、旧代次回调和快速连续重试边界，再将按钮改为只推进代次并实现同代次单飞
- [x] 3.2 先补终端双标签失败测试，覆盖一个标签 `exit`、显式关闭和 Socket 错误，再按标签句柄精确释放并确保另一标签保持可交互
- [x] 3.3 先补 SFTP Store/Pane Source 失败测试，覆盖持久句柄正常操作、标签关闭、无效句柄和同主机双标签，再迁移全部远端文件操作到标签句柄
- [x] 3.4 先补 Workspace/Transfer 失败测试，覆盖 SFTP 标签关闭后传输继续、任务终态释放和无标签边界，再删除按主机延迟断开的协调状态与静默 `disconnectHost`

## 4. 监控与日志（TDD）

- [x] 4.1 先补遥测失败测试，覆盖所有者关联、正常结束、异常关闭、空闲和已释放连接边界，再扩展 Rust/FFI/Swift 监控模型与页面显示
- [x] 4.2 先补日志失败测试，覆盖连接成功、exit、显式关闭、EOF/读写/keepalive 错误、重试及敏感内容边界，再接通 SSH/SFTP/传输生命周期日志并移除静默错误吞噬

## 5. 验证、归档与质量门禁

- [x] 5.1 运行 OpenSpec 严格校验、格式化、`cargo test` 和改动的 Swift XCTest，修复全部失败
- [x] 5.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`，补足缺失的正常、意外与边界分支测试
- [x] 5.3 运行跨平台 Rust 检查及 `build-rust.sh` → `xcodegen` → macOS/iPadOS 双端构建
- [x] 5.4 人工验证同主机双终端：一个执行 `exit`、单击一次重试、空闲超过 30 秒、检查监控与日志；通过标准为无重复 Socket、无跨标签断开且原因可追踪
- [x] 5.5 将规格 delta 合并回主规格、更新 connection-pool Purpose 为显式所有权语义、归档变更并再次执行严格校验与仓库状态审计

完整验证证据见 `verification.md`。真实主机验收严格只执行了获准的 `exit`，未执行其他远端命令；5.5 在规格同步与归档完成后关闭。
