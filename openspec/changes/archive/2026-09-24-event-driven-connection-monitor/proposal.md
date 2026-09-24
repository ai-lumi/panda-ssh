## Why

连接监控目前每次读取后等待一秒再轮询，导致状态显示滞后，空连接时也反复切换加载状态。用户要求界面由底层实际状态变化驱动，移除固定周期读取。

## What Changes

- Rust 遥测层提供可取消的快照订阅，覆盖连接、所有者、通道、流量、健康检查及移除事件。
- FFI 使用既有全局 runtime 投递快照；SwiftUI 在页面生命周期内订阅，删除一秒轮询。
- 无变化不发布，无连接不调度到期任务；速率归零、空闲判定由活动触发的一次性到期事件完成。
- 区分首次加载、手动刷新与自动推送，空状态不反复显示加载提示。

## Non-goals

不修改 SSH 连接、认证、keepalive、健康探测规则或生命周期日志；不新增网络请求、依赖或持久化数据；不将页面做成保存每个中间事件的审计日志。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `connection-monitoring`：以事件订阅替换周期快照读取，规定空态、取消与时间派生状态。
- `ffi-bridge`：增加同步订阅入口、回调及可取消句柄，沿用简单值类型快照。

## Impact

影响 `panda-core::telemetry`、`panda-ffi::ffi_telemetry`、生成的 Swift 绑定、`ConnectionMonitorStore/View` 与对应测试。macOS 独立窗口和 iPadOS 页面共用同一订阅行为。现有同步查询及手动健康检查接口保持兼容。
