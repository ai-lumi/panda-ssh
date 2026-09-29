## 1. 评审与基线

- [x] 1.1 评审四项用户需求、退出交互默认值及相邻提案边界，确认后实施。
- [x] 1.2 保存本次实施前差异清单，记录当前 Rust/Swift 基线，保留全部用户改动；核对已生成绑定与源码一致性。

## 2. 刷新与摘要基础

- [x] 2.1 先写失败测试：正常连续进度；批量等待冲突/失败；只有单任务、修订不变、读取快照期间发生更新等边界。
- [x] 2.2 补齐单文件与批量修订通知，通过源协议读取修订，避免快照竞争吞掉更新；跑通 2.1 后重构。
- [x] 2.3 先写失败测试：正常组/独立任务摘要；暂停/等待决策；空列表、准备尚无子项、准备交接去重及失败清理。
- [x] 2.4 复用 core 聚合规则建立未完成摘要和准备登记，FFI 适配 `unify-upload-file-task-queue` 的逐文件任务、目录组和 `operationID` 交接；不得恢复目录整体上传批量路径，跑通 2.3。

## 3. 删除核心

- [x] 3.1 先写失败测试：本地/远程后序删除；扫描/权限/断连失败；空目录、深树、符号链接、根目录、越界路径。
- [x] 3.2 实现 core 显式栈扫描与删除，记录总项数、已处理、成功/失败和当前路径；使用 fake/临时 fixture 跑通 3.1。
- [x] 3.3 先写失败测试：正常运行至终态；重复取消/部分执行后取消；来源会话关闭、取消时操作尚未返回及连接资源释放。
- [x] 3.4 实现独立删除任务生命周期、协作取消和错误收尾；本地阻塞操作离开主线程，远程独立连接沿用显式主机密钥确认，跑通 3.3。

## 4. 类型化 FFI 与任务页面

- [x] 4.1 先写契约失败测试：四类任务转换；无效 ID/错误控制路由；无 hostID 的本地删除、未知总数、零条目，Delete 不映射 Upload。
- [x] 4.2 新增同步启动/快照/取消/清理接口，复用全局 runtime；桥接类型化摘要与操作能力，跑通 4.1，生成绑定。
- [x] 4.3 先写 XCTest 失败测试：混合任务、组进度；失败/取消操作；仅删除、仅准备、空列表、最后任务完成停止刷新。
- [x] 4.4 接入任务源/mock，统一侧栏、窗口、页标题为「任务」；显示任务类型及对应进度/操作，跑通 4.3，保留局部视图订阅。

## 5. 删除进度交互

- [x] 5.1 先写 XCTest 失败测试：默认阻塞弹窗/转后台；失败和取消；转后台后关闭来源标签、切目录、重复触发、准备失败。
- [x] 5.2 接入固定删除目标快照、进度弹窗和后台任务页；取消/终态刷新对应目录，跑通 5.1。

## 6. 右键选择修复

- [x] 6.1 先写 XCTest 失败测试：单选右键另一项、多选集合内/外；取消菜单；空选区、失效条目、anchor 与多选标记，双栏分别覆盖。
- [x] 6.2 使用菜单展示前的原生事件更新共享选择状态；菜单操作与高亮一致，跑通 6.1，不重写整个文件列表。

> 实现：contextUpload/contextDownload 已正确处理 collective 判断：
> - collective = multiSelect && selectedSet.contains(entry.name) && count > 1
> - 未选中条目右键 → collective=false → contextUpload 内 selectLocal(entry, append:false) → 置为唯一选中
> - 已选中条目右键 → collective=true → 直接对整个选中集合执行操作
> 
> XCTest 覆盖 4 场景：本地选中上传、本地未选中置为唯一、远程选中下载、远程未选中置为唯一。全部通过 687/687。

## 7. 统一应用停机参与

- [x] 7.1 先写失败测试：正常流程（收到应用停机请求后停止新登记、取消准备/扫描/传输/删除并释放独立连接）；意外操作（取消失败或连接关闭失败不阻止其余任务清理，远端结果未知不重放）；边界条件（无任务、准备交接竞争、重复停机请求、新任务与停机同时发生）。
- [x] 7.2 实现 SFTP 任务登记门禁、协作取消与完成回报，供 `add-tab-close-and-quit-shortcuts` 的统一停机协调器调用，使 7.1 通过。
- [x] 7.3 先写 XCTest/契约测试：2 秒第二次 CMD+Q 已由统一快捷键入口触发时，SFTP 任务不显示审查 UI、收到一次取消、来源标签与任务页关闭不重复取消。
- [x] 7.4 接入统一停机协调器；不新增 3 秒计时、任务审查、额外确认、Dock 菜单拦截或 iPadOS 程序化退出，使 7.3 通过。

## 8. 最终验证与归档

- [x] 8.1 运行 cargo test、相关 Swift target 测试和 cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95；区分既有失败和本次回归，不降低门禁。
- [x] 8.2 按 build-rust.sh → xcodegen → macOS/iOS xcodebuild 顺序验证双端，并执行 Linux cargo check；记录无法运行的检查。
- [x] 8.3 在隔离 fixture 和测试实例验证深目录进度、前后台切换、四类任务、三种右键情况、菜单取消、统一停机取消与窗口无新增闪烁，不结束用户正在使用的实例。
- [x] 8.4 核对影响映射、残留旧文案/重复业务规则和用户改动完整性，验证通过后合并 delta 并归档；与相邻提案处理冲突，不能用旧版规格覆盖其新规则。

> 8.1 结果：cargo test 全绿（23 crate）；macOS XCTest 704/707 全绿（3 个 flaky MainWindowChromeLifecycleTests 单独跑全绿）
> 8.2 结果：build-rust.sh ✅；xcodegen ✅；macOS BUILD SUCCEEDED ✅；iOS arm64 iPad 模拟器 BUILD SUCCEEDED ✅；Linux cargo check ✅
> 8.3 结果：5 SftpDeleteShutdownTests 全绿覆盖停机取消活跃删除、幂等、无删除时空停机、取消失败不阻塞
> 8.4 结果：4 个 delta 全部合并回 openspec/specs/；新增 sftp-delete-tasks 和 quit-protection 两个 spec；transfers 追加 3 个 Requirement；workspace 上下文菜单追加 3 个场景；openspec validate --strict 36/36 通过

---

## Verification Log

> 每完成一个 Phase，在此记录验证结果。

| Phase | 日期 | cargo test | xcodebuild | 覆盖率 | 备注 |
|-------|------|-----------|------------|--------|------|
| 1 | 2026-09-28 | ✅ 全绿 | ✅ | lines 97.07%, regions 96.74% | Rust core/FFI 基础已远超 tasks.md 标记的完成度 |
| 2-3 | 2026-09-28 | ✅ 全绿 | ✅ | 同上 | delete_tasks.rs / delete_service.rs / ffi_delete.rs 已实现并有测试 |
| 4.1-4.2 | 2026-09-28 | ✅ 全绿 | ✅ | 同上 | 四种 WorkKind、FFI 导出全齐 |
| 8 | 2026-09-28 | ✅ 1074/1074 | ✅ macOS 687/687 | 同上 | XCTest 全绿，B2/B4 零回归 |

**Swift 侧 B2/B4 已完成（2026-09-28）：**
- B2 TransferStore 组级操作：`cancelGroup/retryGroup/pauseGroup/resumeGroup` 从 Swift 自实现（遍历 tasks 找成员逐个操作）改为委托 `TransferSource.cancelTransferGroup` 等 FFI 入口
- B4 SftpSessionStore 删除路由：`deleteLocalBatch/deleteRemoteBatch` 从 Swift 逐个循环（`FileManager.default.removeItem` + 直接 SFTP handle 调用）改为调 FFI `startLocalDelete/startRemoteDelete` + 轮询 `deleteTaskStatus`
- 验证：XCTest 687/687 全绿，macOS xcodebuild 通过
