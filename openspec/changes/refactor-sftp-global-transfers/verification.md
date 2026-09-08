# 验证记录（2026-09-08）

## 变更结果

SFTP 已移除额外标题工具栏与全部传输侧面板呈现。主窗口左下角以传输任务替换预留代码片段入口，显示活动任务数；macOS 使用唯一 Window 场景，iPadOS 使用工作区路由。任务页面观察应用共享 TransferStore，展示源、目标、双方路径、速度、进度及状态，保留已有单任务与任务组操作。

后台 macOS 终端同步设置原生 isHidden，撤销光标区域并使其失效；当前全局页面不是主机工作区时也会隐藏终端原生视图。地址栏非文本按钮采用连续悬停箭头反馈，路径 TextField 保留原生文本光标。

## 已验证

- TDD：新增测试先因缺少 showTransfers、TransferPageView、updatePresentationVisibility 等接口失败，再实现后通过。
- macOS 定向测试：61 项通过。
- macOS 全量测试：501 项通过，0 失败。
- iPad 模拟器全量测试：451 项通过，0 失败。
- 构建链：build-rust.sh → xcodegen → macOS 测试构建／arm64 iPad 模拟器构建通过。
- cargo test --offline：通过。
- cargo llvm-cov --workspace --tests --offline --fail-under-lines 95 --fail-under-regions 95：通过；lines 96.47%、regions 95.06%。
- 基于实施前备份审阅增量 diff，原有未提交工作区改动保留。本次源码与规格的 diff --check 通过；生成 FFI 头文件另有两处尾随空白，未额外格式化生成物。

## 发现与处理

- 默认沙箱禁止 Xcode 缓存写入和测试回环监听；经自动审批允许的构建／测试命令重跑通过，未接触真实 SSH 主机。
- SwiftTerm 的光标方法非 open，不能在外部 override；最终通过 AppKit 原生可见性与光标区域失效处理，没有修改第三方包。
- 旧 TabBarLayoutProbeTests 直接创建 WorkspaceView，缺少现有顶部栏所需的 MacOSWorkspaceChromeMetrics，已补齐测试环境；测试旧内容区页签行时显式选择 legacy 策略，保留原断言。
- generic iOS 模拟器构建尝试额外链接 x86_64，现有 xcframework 仅提供 arm64 模拟器产物；改用工程支持的 arm64 iPad 模拟器后通过，未扩展平台架构范围。

## 未完成验收与边界

- Swift 全应用 xccov 行覆盖率曾为 49.45%，包含 SwiftUI 与生成绑定，未达到全代码 95% 要求；全局补测第一批后为 61.76%，仍未满足。统计口径未排除文件；Rust 的 95% 门禁通过不能代表 Swift 覆盖率通过。
- 原生终端隐藏／恢复与命中测试通过；用户已在真实运行界面验证路径编辑前后、刷新／选择／路径图标的光标。
- 还需人工检查宽窄布局、重复激活传输窗口和页面关闭后任务继续。未执行真实文件传输，也未截取用户屏幕。
- 已同步当前规格，变更保持未归档，待上述验收及覆盖率要求满足。未提交或发布。

本次新建的 iOS DerivedData 已移到 `/private/tmp/panda-transfer-deriveddata-ios`，避免生成物混入仓库。
