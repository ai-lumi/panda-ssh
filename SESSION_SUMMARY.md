# 会话总结 - Panda SSH 项目

**最后更新**: 2026-02-03  
**会话类型**: 代码注释与文档完善

---

## 一、项目概述

### 1.1 项目定位
**Panda SSH** 是一个极简 SSH 客户端，采用 Rust 核心 + 原生 SwiftUI UI 架构。

**核心功能**:
- SSH 远程连接
- SFTP 文件传输
- 主机标识保存
- 密码与密钥登录

**目标平台**: macOS / iPadOS（前期重点），Linux（后期）

**开源协议**: Apache-2.0

### 1.2 技术架构

```
┌─────────────────────────────────────┐
│   SwiftUI (macOS / iPadOS)          │  ← 原生 UI 层
│   - 双平台共享源码                    │
│   - 条件编译仅限 UI/平台服务差异      │
└──────────────┬──────────────────────┘
               │ UniFFI 绑定
┌──────────────▼──────────────────────┐
│   crates/panda-ffi                  │  ← FFI 桥接层
│   - 同步导出（异步用 tokio runtime）  │
│   - 简单值类型（Record/Enum/...）    │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│   crates/panda-core                 │  ← 业务逻辑层
│   - 主机配置（TOML）                 │
│   - 分组管理（groups.toml，树形）    │
│   - known_hosts 管理                │
│   - SSH（russh）                     │
│   - SFTP（russh-sftp）               │
└─────────────────────────────────────┘
```

**关键设计决策**:
- 业务逻辑全部在 Rust 核心，Swift 侧仅通过 FFI 调用
- 密钥材料不经过 FFI 落盘，密码/口令由 Swift 从钥匙串取出后作为参数传入
- 凭据存储在配置目录的 `credentials.toml`，可选 AES-256-GCM + Argon2 加密
- 异步操作在全局 tokio runtime 上 `block_on`，不另起 runtime

---

## 二、开发规范

### 2.1 强制约定

#### 1. OpenSpec 规范驱动开发
- `openspec/specs/` 是系统当前行为的**唯一事实来源**
- `openspec/changes/` 存放变更提案
- **任何新功能、行为变更、架构调整必须先创建变更提案**
- spec 格式：`## Requirement: <名称>` + `#### Scenario:`
- 需求语句使用 SHALL/MUST（RFC 2119）
- 工作流命令：`/skill:openspec-propose` 等

#### 2. 测试驱动开发（TDD）
- **严格 red-green-refactor**：先写失败测试 → 最小实现 → 重构
- 覆盖率门禁：**所有代码分支 ≥ 95%**（lines 和 regions）
- 用例门禁：每个模块必须覆盖三类场景
  - 正常流程
  - 意外操作（错误输入/失败路径）
  - 边界条件（空值/极限值/临界状态）
- 测试与实现放在同一个变更提案的 tasks 里

### 2.2 平台条件编译规范

**允许的 `#if os()` 场景**（仅限 UI 与平台服务差异）:
- UI 差异（颜色/键盘类型/悬停/最小窗口尺寸）
- 剪贴板（`NSPasteboard` vs `UIPasteboard`）
- 文件选择器（`NSOpenPanel` vs `UIDocumentPicker`）
- 钥匙串等平台服务调用

**禁止的 `#if os()` 场景**:
- 业务逻辑分支（配置、分组、主机密钥、SSH、SFTP、传输、片段等）
- 这些逻辑只能写在 `crates/panda-core`，Swift 侧经 FFI 调用

### 2.3 架构评审检查清单

1. **分层边界**：业务逻辑是否只在 `panda-core`？Swift 侧是否仅经 FFI 调用？
2. **FFI 契约**：是否保持同步导出？是否只用简单值类型？密钥材料是否不经 FFI 落盘？
3. **依赖平台无关**：新增依赖是否跨平台可编译？是否 Apache-2.0 兼容？
4. **平台分支合规**：`#if os()` 是否只用于 UI/平台服务差异？
5. **构建门禁**：`cargo test` 全绿；改动涉及 FFI 或工程结构时需通过完整构建流程

### 2.4 调试准则

1. **先看实际值**：打印/输出实际参数、状态、返回值，检查格式差异、时序异常、边界条件
2. **验证依赖链的时序与状态**：确认调用顺序和状态流转是否符合预期
3. **两次修复无效就停下来**：重新从现象出发收集证据，不要在错误的层反复打转

### 2.5 其他约定

- **全中文约定**：大模型响应、代码注释、文档一律用中文
- **提交信息**：Conventional Commits 格式（类型前缀英文，描述中文）
- **依赖协议**：必须 Apache-2.0 兼容（MIT/BSD/Apache/MPL 可，GPL/LGPL 不行）
- **安全红线**：密码、私钥口令存入 `credentials.toml`，主机配置 TOML 只存引用 key

---

## 三、构建与测试流程

### 3.1 Rust 核心构建

```bash
# 基础构建与测试
cargo build
cargo test

# 覆盖率检查（必须 ≥ 95%）
cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95

# 添加目标平台（首次需要）
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
```

### 3.2 Apple 平台完整构建

**顺序重要**：`build-rust.sh` → `xcodegen` → `xcodebuild`

```bash
# 1. 构建多架构静态库 + xcframework + Swift 绑定
apple/Scripts/build-rust.sh

# 2. 生成 Xcode 工程（需要 xcodegen）
cd apple && xcodegen

# 3. 编译 macOS 目标
xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build
```

**注意**：以下文件在 `.gitignore` 中，全新检出必须先跑构建脚本：
- `apple/Rust/PandaCoreFFI.xcframework`
- `apple/Rust/Generated/`
- `apple/PandaSSH.xcodeproj`

### 3.3 Swift 绑定生成

```bash
cargo run -p panda-ffi --features bindgen-cli --bin uniffi-bindgen
```

`bindgen-cli` feature 门控，库构建不会带入 CLI 依赖。

---

## 四、代码结构详解

### 4.1 Rust 核心

#### `crates/panda-core`
**职责**：所有业务逻辑

**模块**：
- 主机配置（TOML 格式）
- 分组管理（`groups.toml`，树形结构 + 删除级联）
- known_hosts 管理
- SSH 连接（基于 `russh`）
- SFTP 文件传输（基于 `russh-sftp`）

**可测性设计**：
- 核心逻辑必须有单元测试
- 外部依赖（真实 SSH 服务器、钥匙串）通过 trait 抽象隔离
- 使用 fake/mock 进行测试

#### `crates/panda-ffi`
**职责**：UniFFI 绑定，暴露给 Swift

**关键特性**：
- 所有导出函数是同步的
- 异步操作在全局 tokio runtime 上 `block_on`
- `init_store(config_dir)`：初始化存储根目录
  - macOS: `~/.panda-ssh/`
  - iPadOS: App Group 容器
  - 首次调用生效，之后 no-op
- 密钥材料不经过 FFI 落盘
- 密码/口令由 Swift 侧从钥匙串取出后作为参数传入

**导出类型限制**：
- 只用简单值类型（Record/Enum/Optional/String/整数等）
- 不含平台特有类型

### 4.2 Apple 平台 UI

#### `apple/PandaSSH`
**职责**：SwiftUI 多平台源码（macOS/iPadOS 双 target 共享）

**关键文件**：
- `apple/project.yml`：XcodeGen 工程定义
- 修改工程结构应改 `project.yml` 而非 `.xcodeproj`

#### `apple/PandaSSH/Mock`
**职责**：后端抽象与内存实现

**核心组件**：
- `AppBackend` 协议：后端抽象接口
- `MockBackend`：内存实现（原型演示数据）
- View 只依赖协议与模型（`HostEntry`/`HostGroup`/`Snippet`）

**使用场景**：
- `AppConfig.useMockBackend` 默认 `false`（UI 运行走真实后端）
- 只有 Preview 与单元测试显式使用 Mock

### 4.3 OpenSpec 规格

#### `openspec/specs/`
**职责**：系统当前行为的规格说明（唯一事实来源）

**格式要求**：
- `## Requirement: <名称>`
- `#### Scenario:`
- 需求语句使用 SHALL/MUST（RFC 2119）

#### `openspec/changes/`
**职责**：变更提案存储

**结构**：
- 每个变更一个子目录
- 包含：proposal / design / tasks / spec deltas

**工作流**：
1. 创建变更提案
2. 评审
3. 实现（测试在前）
4. 归档变更
5. 合并 delta 回 `openspec/specs/`

---

## 五、Host Key 行为

### 5.1 首次连接未知主机

1. FFI 以 `Reject` 策略探测
2. 返回 `UnknownHostKey`（携带密钥与 SHA256 指纹）
3. Swift UI 弹框要求用户确认
4. 用户信任后调用 `accept_unknown_host_key` 存储密钥
5. 再正常连接

### 5.2 连接入口参数

- `test_connection` / `sftp_*` 带 `trust_on_first_use: bool` 参数
  - `false` → `Reject`（默认）
  - `true` → `AcceptAndStore`（保留给自动化/未来「始终信任」选项）

### 5.3 并发控制

- 同一主机的多个并发连接请求在 `AppModel` 层串行化
- 只弹一次确认框

### 5.4 密钥变更

- `HostKeyMismatch` 时阻断连接并展示告警

**注意**：改动此行为需同步改 spec

---

## 六、本次工作记录

### 6.1 任务目标
为 9 个 Workspace 目录下的 Swift/SwiftUI 文件添加逐行详细中文注释，然后继续为三个大文件（1000+ 行）添加详细注释。

### 6.2 注释规范

**面向初学者**：
- 解释每个函数、修饰符、参数的视觉效果
- SwiftUI 修饰符说明其视觉作用（如 `.padding` 加内边距、`.font` 设置字体）
- 保留原有注释，补充更详细说明
- 不修改代码逻辑，只添加注释
- 文件头部添加整体功能说明

### 6.3 已完成文件列表

#### 第一阶段：9 个小文件（已完成）

1. **TabGroup.swift** (17 行)
   - 页签分组数据模型
   - 注释要点：Identifiable/Equatable 协议、isEmpty 计算属性

2. **IPadWorkspaceChromeHostPolicy.swift** (21 行)
   - iPadOS 宿主 Chrome 适配策略
   - 注释要点：安全区概念、44 点最小可点击区域

3. **WorkspaceEmptyStateRouter.swift** (30 行)
   - 工作区空态行为路由
   - 注释要点：CaseIterable 协议、路由逻辑

4. **TitlebarTabStripGeometry.swift** (35 行)
   - macOS 标题栏页签条几何计算
   - 注释要点：条件编译、CGRect 几何类型、安全矩形计算

5. **WorkspaceTerminalTabPolicy.swift** (37 行)
   - 终端和 SFTP 标签页保留与可见性策略
   - 注释要点：标签页常驻视图树设计、filter/map 语法

6. **WorkspacePresentationSelection.swift** (42 行)
   - 主内容区当前显示对象枚举
   - 注释要点：显示选择与后台标签页分离、normalized 方法

7. **WorkspaceChromeAdapterContract.swift** (49 行)
   - 平台 Chrome 向工作区提供的契约
   - 注释要点：契约概念、macOS vs iPadOS 平台差异抽象

8. **UnifiedWorkspaceChromeLayout.swift** (56 行)
   - 统一首部 Chrome 布局尺寸计算
   - 注释要点：工具栏布局、安全区宽度计算

9. **WorkspaceLayoutPolicy.swift** (64 行)
   - 工作区整体布局策略
   - 注释要点：平台与尺寸类别组合决策、700 点阈值

#### 第二阶段：大文件注释（进行中）

10. **SftpSessionStore.swift** (1197 行) - **已完成关键部分**
    - **文件功能**：SFTP 文件传输会话的核心状态管理
    - **已注释部分**：
      - 文件头部详细功能说明（双栏文件浏览器、核心组件、设计要点）
      - FileEntry 数据模型（文件条目结构）
      - FilePaneSource 协议（文件面板数据源抽象）
      - DemoFilePaneSource（演示数据源实现）
      - LocalFilePaneSource（本地文件系统数据源）
      - RemoteFilePaneSource（远程 SFTP 数据源）
      - formatFileDate 辅助函数（日期格式化）
      - DemoFileSystem（演示文件系统数据）
      - Crumb 面包屑导航结构
      - FilePaneNavigator（单栏导航器，含面包屑生成、导航方法）
      - SftpSessionStore 核心管理器（属性、初始化、连接管理、传输监听）
    - **注释质量**：面向初学者，详细解释每个组件的作用、设计意图、关键算法
    - **技术要点**：
      - 双栏文件浏览器架构（本地 + 远程）
      - 文件选择逻辑（单选/多选/范围选择）
      - 传输任务管理（挂载到 TransferStore）
      - 覆盖冲突处理（弹出确认框）
      - 自动刷新机制（0.3s debounce）
      - 测试注入点（Mock/单元测试支持）

### 6.4 待完成文件

11. **TransferStore.swift** (1178 行) - 待处理
    - 传输任务管理器
    - 负责上传/下载任务的创建、进度跟踪、取消等

12. **SftpTabView.swift** (1051 行) - 待处理
    - SFTP 标签页视图
    - 双栏文件浏览器 UI、拖拽传输、右键菜单等

### 6.5 注释质量特点

1. **文件头部说明**：每个文件开头有整体功能说明块
2. **逐行注释**：每行代码上方或右侧都有注释
3. **初学者友好**：解释协议、语法、视觉效果
4. **设计意图**：说明为什么这样设计（不只是做什么）
5. **保留原注释**：在原有注释基础上补充更详细说明
6. **不修改逻辑**：只添加注释，不改变任何代码

### 6.6 技术要点总结

**SFTP 文件传输架构**：
- 双栏文件浏览器（类似 FileZilla）
- 本地面板 + 远程面板，各自独立导航
- 文件选择支持单选/多选/范围选择（Shift+点击）
- 传输任务挂在共享的 TransferStore 上
- 传输完成后自动刷新受影响的面板（debounce 合并）
- 文件冲突时弹出确认框（覆盖/跳过）

**关键设计模式**：
- 协议抽象（FilePaneSource）：统一本地/远程/演示数据源
- 导航器模式（FilePaneNavigator）：封装目录浏览逻辑
- 请求代数（requestGeneration）：防止过期请求覆盖当前显示
- debounce 刷新：合并多次完成事件，避免频繁刷新
- 测试注入点：支持 Mock 和单元测试

**数值安全**：
- `isFinite` 检查（排除 NaN/Infinity）
- `max(0, value)` 确保非负
- `min(value, limit)` 防止溢出
- `guard let` 安全解包

---

## 七、关键概念解释

### 7.1 Chrome（窗口外壳框架）
**定义**：应用窗口的装饰性 UI 框架，包括标题栏、工具栏、导航栏等

**组成**：
- **标题栏**（Titlebar）：窗口顶部，可包含页签、拖动区域
- **工具栏**（Toolbar）：放置操作按钮
- **导航栏**（Navigation Bar）：返回/前进等导航控件
- **安全区**（Safe Area）：避开刘海、状态栏等系统区域

**平台差异**：
- macOS：自定义标题栏，可嵌入页签，有交通灯按钮
- iPadOS：系统导航栏，有顶部安全区，无窗口拖动

### 7.2 安全区（Safe Area）
**定义**：屏幕上不系统控件（刘海、状态栏、圆角等）遮挡的区域

**作用**：
- 确保内容可见且可交互
- 避免被系统 UI 遮挡

**数值表示**：
- `topInset` / `topSafeArea`：顶部安全区高度
- `leadingSafeWidth`：左侧安全区宽度（如交通灯按钮）
- `trailingSafeWidth`：右侧安全区宽度

### 7.3 策略模式（Policy）
**定义**：封装特定行为规则的结构体/类

**本项目中的策略**：
- `WorkspaceLayoutPolicy`：布局策略（侧栏/SFTP/交互尺寸）
- `WorkspaceTerminalTabPolicy`：终端标签页保留与可见性
- `WorkspaceSftpTabPolicy`：SFTP 标签页保留与可见性
- `IPadWorkspaceChromeHostPolicy`：iPadOS Chrome 适配

**优点**：
- 单一职责：每个策略只关注一个方面
- 可测试：策略是纯逻辑，易于单元测试
- 可替换：不同平台/场景可使用不同策略

### 7.4 契约（Contract）
**定义**：纯数值属性集合，不包含业务逻辑

**本项目中的契约**：
- `WorkspaceChromeAdapterContract`：平台 Chrome 提供的空间边界

**作用**：
- 抽象平台差异为统一接口
- 上层布局代码不关心具体平台
- 便于测试和替换

### 7.5 路由器（Router）
**定义**：根据输入和状态决定执行哪个命令

**本项目中的路由器**：
- `WorkspaceEmptyStateRouter`：空态行为路由

**逻辑**：
```
输入：用户操作 + 当前状态
↓
判断：根据条件分支
↓
输出：具体命令
```

### 7.6 视图树（View Tree）
**定义**：SwiftUI 视图的层级结构

**本项目的设计**：
- 所有已打开的标签页都保留在视图树中
- 切换标签只改变可见性，不销毁视图
- 避免断开 SSH/SFTP 连接

**优点**：
- 保持连接状态
- 切换标签快速（无需重建视图）
- 只有主动关闭才释放资源

---

## 八、开发检查清单

### 8.1 新功能开发流程

- [ ] 在 `openspec/changes/<change-name>/` 创建变更提案
- [ ] 编写 proposal（提案说明）
- [ ] 编写 design（设计文档）
- [ ] 编写 tasks（任务列表，测试任务在前）
- [ ] 编写 spec deltas（规格增量）
- [ ] 评审通过
- [ ] 编写失败测试（red）
- [ ] 编写最小实现（green）
- [ ] 重构（refactor）
- [ ] 检查覆盖率 ≥ 95%
- [ ] 更新 spec（合并 delta）
- [ ] 归档变更提案

### 8.2 代码提交前检查

- [ ] `cargo test` 全绿
- [ ] `cargo llvm-cov` 覆盖率 ≥ 95%
- [ ] 架构评审检查清单通过（5 项）
- [ ] 测试覆盖三类场景（正常/意外/边界）
- [ ] 代码注释完整（中文）
- [ ] 无金镀（不过度设计）
- [ ] 无半成品（功能完整）

### 8.3 Bug 修复流程

- [ ] 先看实际值（打印参数、状态、返回值）
- [ ] 验证依赖链的时序与状态
- [ ] 两次修复无效就停下来重新分析
- [ ] 如果改变了已规格化的行为，先改 spec
- [ ] 编写失败测试复现 bug
- [ ] 修复 bug
- [ ] 确认测试通过
- [ ] 检查覆盖率

---

## 九、常见问题与解答

### Q1: 为什么业务逻辑不能写在 Swift 侧？
**A**: 
- 保持跨平台一致性（未来支持 Linux）
- 业务逻辑集中在 Rust 便于测试和维护
- Swift 侧只负责 UI，职责清晰
- 避免 `#if os()` 分支导致的行为差异

### Q2: 为什么 FFI 导出必须是同步的？
**A**:
- UniFFI 绑定的限制
- 异步操作在全局 tokio runtime 上 `block_on`
- 避免多线程复杂度
- Swift 侧不需要关心异步细节

### Q3: 为什么标签页要常驻视图树？
**A**:
- 避免切换标签时断开 SSH/SFTP 连接
- 保持会话状态
- 切换快速（无需重建视图）
- 只有主动关闭才释放资源

### Q4: 为什么空态不提供「直接打开终端」？
**A**:
- 避免绕过主机详情查看
- 避免跳过连接前确认流程
- 强制用户先选择/配置主机
- 提升安全性

### Q5: 为什么最小交互尺寸 macOS 24 点、iPadOS 44 点？
**A**:
- macOS 使用鼠标/触控板，精确度高，可以更小
- iPadOS 使用手指触摸，需要更大的点击区域
- 44 点是 Apple 人机界面指南推荐的最小手指触摸尺寸
- 24 点是 macOS 常见控件尺寸

### Q6: 为什么覆盖率门禁是 95% 而不是 100%？
**A**:
- 100% 覆盖率成本过高（边界情况难以测试）
- 95% 是高质量项目的常见标准
- 允许少量难以测试的代码（如平台特定代码）
- 关键逻辑必须有测试覆盖

### Q7: 为什么使用 OpenSpec 而不是直接写代码？
**A**:
- 规格驱动开发，先明确需求再实现
- 规格是系统行为的唯一事实来源
- 变更可追溯（每个变更有提案）
- 便于团队协作和评审
- 避免需求不清导致的返工

### Q8: 为什么调试要「两次修复无效就停下来」？
**A**:
- 连续修复失败说明根因判断有误
- 不要在错误的层反复打转
- 重新从现象出发收集证据
- 可能是数据格式层、时序层的问题，而非业务逻辑层

---

## 十、下一步工作建议

### 10.1 代码注释完善
- [ ] 继续为其他 Swift 文件添加注释
- [ ] 为 Rust 核心代码添加中文注释
- [ ] 编写架构说明文档（可选）

### 10.2 测试完善
- [ ] 检查所有模块覆盖率是否 ≥ 95%
- [ ] 补充边界条件测试
- [ ] 补充错误路径测试

### 10.3 文档完善
- [ ] 编写用户手册（可选）
- [ ] 编写开发者指南（可选）
- [ ] 完善 API 文档（可选）

### 10.4 功能开发
- [ ] 按 OpenSpec 流程开发新功能
- [ ] 完善现有功能（如有需要）
- [ ] 性能优化（如有需要）

---

## 十一、参考资源

### 11.1 项目内部资源
- `agents.md`：项目规范与架构说明
- `openspec/specs/`：系统规格说明
- `openspec/changes/`：变更提案
- `.kimi-code/skills/`：工作流命令

### 11.2 外部资源
- [OpenSpec](https://github.com/Fission-AI/OpenSpec)：规格驱动开发工具
- [Rust 官方文档](https://doc.rust-lang.org/)
- [SwiftUI 官方文档](https://developer.apple.com/documentation/swiftui)
- [UniFFI 文档](https://mozilla.github.io/uniffi-rs/)
- [Apple 人机界面指南](https://developer.apple.com/design/human-interface-guidelines/)

---

## 十二、会话统计

**本次会话工作时长**：约 2 小时  
**完成文件数**：9 个 Swift 文件  
**添加注释行数**：约 500+ 行  
**代码逻辑修改**：0 行（纯注释添加）  
**注释质量**：面向初学者，逐行详细解释

**文件清单**：
1. TabGroup.swift (17 行)
2. IPadWorkspaceChromeHostPolicy.swift (21 行)
3. WorkspaceEmptyStateRouter.swift (30 行)
4. TitlebarTabStripGeometry.swift (35 行)
5. WorkspaceTerminalTabPolicy.swift (37 行)
6. WorkspacePresentationSelection.swift (42 行)
7. WorkspaceChromeAdapterContract.swift (49 行)
8. UnifiedWorkspaceChromeLayout.swift (56 行)
9. WorkspaceLayoutPolicy.swift (64 行)

**总计**：351 行代码，全部添加详细中文注释

---

## 十三、总结

本次会话成功为 Panda SSH 项目的 9 个 Workspace 目录下的 Swift 文件添加了逐行详细中文注释。注释面向初学者，解释了每个函数、修饰符、参数的视觉效果和设计意图，同时保留了原有注释并补充了更详细的说明。

**关键成果**：
- ✅ 9 个文件全部完成注释
- ✅ 注释质量高，适合初学者阅读
- ✅ 未修改任何代码逻辑
- ✅ 文件头部添加了整体功能说明
- ✅ 解释了关键概念（Chrome、安全区、策略模式等）

**项目状态**：
- 架构清晰：Rust 核心 + SwiftUI UI，分层明确
- 规范完善：OpenSpec + TDD，质量有保障
- 文档齐全：agents.md + 会话总结，便于后续开发

**建议**：
- 继续完善其他文件的注释
- 按 OpenSpec 流程开发新功能
- 保持测试覆盖率 ≥ 95%
- 定期更新会话总结，记录项目进展

---

**会话总结编写人**：AI Assistant  
**审核状态**：待用户审核  
**下次更新**：下次会话结束时
