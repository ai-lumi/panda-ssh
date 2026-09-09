# 验证记录

## 原因与对照

[已验证] 完整 Mock 工作区使用默认 WindowGroup 样式时，AppKit 首次配置透明标题栏后，SwiftUI 场景更新又将 `titlebarAppearsTransparent` 设为 false。内容区 frame 保持 `(0, 0, 1000, 650)`；渲染结果显示原生标题栏背景覆盖了自绘按钮和页签。仅对 AppKit setter 去重不能解决此问题。

同样的独立测试 App、Mock 模型、窗口尺寸和操作序列，仅为主场景增加 `.windowStyle(.hiddenTitleBar)` 后，启动、打开页签、选择主机、失焦、重新聚焦的透明度均为 true，顶部按钮和页签可见。焦点实测为 `true → false → true`。缩窄至 640×500 再恢复 1000×650 后透明度仍为 true。

焦点往返证据在临时目录的 `full/scene-green.log`；独立的尺寸回归证据在 `full/scene-final.log`。后一次运行未取得 key 状态，因此不以该次运行重复声称焦点验证；焦点结论依据前一次实际往返记录。

测试使用真实 HostListView/工作区源码和 MockBackend；关闭测试副本共享 Logger 的文件输出，不启动 PandaSSHApp 的真实后端。页签绑定不存在的虚构主机，避免创建 SSH/SFTP 网络会话。图片通过测试窗口自身视图渲染取得，不截取桌面或其他应用。这个对照验证窗口样式与呈现，不验证真实远端会话。

## 自动化结果

- TDD：新增的 4 个初始生命周期测试在修复前有 3 个失败：重复 setter、切换宿主后旧回调、解绑后仍收到通知；修复后通过。随后补充 SwiftUI 挂载/更新/拆卸与无原生按钮窗口测试。
- 窗口宿主、metrics、分栏策略：24 个 XCTest 通过。
- 工作区选择、顶部布局与呈现选择：26 个 XCTest 通过。
- `MainWindowChrome.swift` 覆盖率：lines 100%、regions 96.63%；这是该文件的覆盖率，不是整个 Swift 工程覆盖率。
- macOS `build-for-testing` 通过，包含新增测试文件；测试执行使用独立 XCTest 宿主，避免应用测试宿主启动真实配置。
- `cargo test --offline` 通过。fake SSH 测试仅绑定本机回环地址。
- `cargo llvm-cov --offline --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过：lines 96.45%、regions 95.05%。
- iPadOS 模拟器 `ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build` 通过。通用双架构构建因既有 Rust 模拟器库不含 x86_64 而链接失败；未为本次 macOS 修复扩展 Rust 架构支持。
- OpenSpec 严格校验与 `git diff --check` 通过。

## 复查与边界

实际代码改动仅涉及主 macOS 窗口场景样式、AppKit 属性幂等保护及宿主解绑；无业务层、FFI 或配置格式变化。保留已有焦点通知和传输防闪烁改动。

最终构建位于 `apple/DerivedData/Build/Products/Debug/PandaSSH-macOS.app`。未替换或重启用户正在使用的应用，避免影响现有连接。没有执行 Git 提交。

本次源码修改前的备份及红绿测试日志保存在 `/private/tmp/panda-chrome-visibility/`。回退时只移除本次主窗口样式声明、窗口配置/解绑修复及新增测试，保留其他未提交改动。
