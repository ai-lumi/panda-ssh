## Context

动机和范围见 `proposal.md`，用户确认的边界为：程序自行编写的提示与 Rust/FFI 错误说明全部翻译；异常信息原文、底层依赖库错误、远端返回、用户输入不翻译；语言无匹配回退简体中文。

当前集成点：

- `apple/PandaSSH/SettingsView.swift:14` 的标签标题及通用页提示为硬编码中文，错误提示拼接 `localizedDescription`，尚无语言设置。
- `apple/PandaSSH/PandaSSHApp.swift:42` 分别创建主窗口、设置、日志、监控、传输 Scene；只给主窗口注入语言不能覆盖其他窗口。
- `crates/panda-core/src/ssh.rs:910` 的连接失败记录直接保存 `title/detail`；`crates/panda-ffi/src/lib.rs:138` 将部分错误压为 `Core(other.to_string())`。必须在字符串化之前保留程序自定义说明与原始异常的区别。同类最终提示文本还分散在 `ffi_telemetry.rs` 的生命周期 `reason` 与 `ConnectionTelemetryRecord.last_error`、`ffi_transfers.rs`/`batch_transfer.rs` 的快照 `error` 字段中，逐项去向见 proposal.md 的 FFI v2 迁移矩阵。
- `crates/panda-core/src/logger.rs:31` 与 Swift 日志展示当前以最终消息字符串工作，无法在切换语言后重新呈现已有事件。
- `apple/project.yml` 使用 Xcode 16、macOS 14 / iPadOS 17，双端共享源文件及测试目录；当前无应用本地化资源。
- 现有 `ffi-bridge` 要求同步导出、全局 runtime、结构化错误；业务分类和安全策略不能因国际化迁移到 Swift。

## Goals / Non-Goals

**Goals:**

- 建立“语言无关的状态/错误 + 完整双语资源 + 呈现时选语言”的链路，切换不触碰业务生命周期。
- 将所有程序自定义 Rust/FFI 错误纳入可枚举、可验证的映射，包括目前未在 UI 使用的错误。
- 原生资源能力、确定性简体中文回退、双端资源打包和可复现审计形成完整交付闭环。

**Non-Goals:**

- 不引入第三方国际化库、自制通用复数引擎或 Rust 全局可变语言状态。
- 不翻译异常链、依赖库报错与远端数据，不通过字符串内容判断某条原文是否属于程序错误。
- 不借国际化改写核心业务规则、凭据存储方案或系统托管界面；不要求翻译既有日志文件与终端历史。

## Decisions

### 1. 使用原生 String Catalog，简体中文作为源语言和最终回退

在 `apple/PandaSSH/Resources/` 维护资源，使用 `Localizable.xcstrings` 与 `Messages.xcstrings`，两者均包含完整 `zh-Hans`、`en`，源语言为 `zh-Hans`。拆分只按**产生来源**而非显示用途：Swift 侧直接创建的界面、原生菜单、无障碍、Swift 状态提示及其动态模板属于 `Localizable`；Rust/FFI `MessageDescriptorRecord.code` 定义的消息（即使最终显示为 SwiftUI 弹窗，如 TOFU 警告）属于 `Messages`。每个 key 必须在清单中有唯一表所有者，禁止在两个 catalog 重复；跨来源复用同一用户动作时，Swift 应引用 descriptor 对应的 `Messages` key，而不是复制一份 `Localizable` 文案。`apple/project.yml` 同步声明开发语言/本地化资源并确保两端打包，避免只改生成的 `.xcodeproj`。

键采用全小写点分的 `模块.场景.用途` 层级，词元使用 ASCII 小写蛇形；`模块` 仅可为 `app/settings/host/group/snippet/workspace/terminal/sftp/transfer/monitor/log/auth/error`，`场景` 表示动作、状态或失败类别，`用途` 使用 `title/detail/action/label/placeholder/help/accessibility_label/confirm/count` 等受控后缀。示例包括 `settings.language.title`、`host.delete.confirm.title`、`error.auth_failed.detail`、`transfer.files.count`。`Messages` 中的资源键 MUST 与 Rust/FFI message code 完全相同；`Localizable` 键遵循同一层级但不承担 Rust code。键不得以中文句子、英文显示文本、远端文本或平台名命名；同一动作同一语义复用一个键，同字但不同语义分别建键。所有变量标明语义与类型，数量变体交给 String Catalog，不手写英语单复数判断。转义和插值使用原生类型化接口，禁止将用户参数当作 format 模板。

Rust 无须依赖 `.xcstrings` 或 Apple API：Rust 提供语言无关的描述，Apple 应用在自身资源中完成全部程序错误的中英翻译；将来其他前端可消费同样的描述，不在本次实现 Linux 本地化运行时。

**取舍：** 不使用平铺 `.strings` + 手写 `.stringsdict`，减少键/复数分散；不使用第三方库，避免新依赖和部署基线变更。实施需坚持 Xcode 16 已支持的 String Catalog/本地化 API，不采用官方最新示例中需要更高工具链的宏或符号生成功能。

### 2. 一个应用级呈现语言上下文，偏好与有效语言分离

拟新增 Swift 呈现层语言上下文，分别持有 `system / zh-Hans / en` 偏好和 `zh-Hans / en` 有效语言。界面使用语言自称“简体中文”“English”，“跟随系统”双语资源为“跟随系统 / Follow System”。该上下文与业务 `AppModel`、`WorkspaceStore`、`TransferStore` 生命周期相互独立。

仅非敏感、设备本地的 UI 语言偏好存入 `UserDefaults` 自定义应用键，不写 `AppleLanguages`，不修改系统语言，不存入主机 TOML、凭据文件或配置归档。它属于平台呈现偏好，不下沉为 SSH/SFTP 配置规则；Rust 不读取系统语言。

启动时先加载偏好，随后创建用户可见界面。存储注入协议用于测试缺失、非法类型和失败；非法值归一到 `system`。`UserDefaults` 内存更新立即、落盘异步且普通 `set` 不提供磁盘失败返回值，不伪造同步写盘保证、不调用 `synchronize()`。仅可检测的受管理键/存储适配失败才提示并保留旧偏好；普通 `UserDefaults` 不虚构不可观测的写入失败。正常重启持久化以独立应用进程验收。依官方要求核对并补充必要的隐私清单声明，不扩大数据采集范围。

系统匹配使用 Foundation 公开语言标识和 Bundle 匹配能力：先按有序偏好处理支持的语言家族及地区/文字兼容关系，再选择有效资源。`Bundle.preferredLocalizations` 在无匹配时仍可能返回候选值，因此不能仅将其第一个返回值当作“匹配成功”；空列表和没有兼容语言必须显式返回 `zh-Hans`，也不能在第一项不支持时提前回退。测试固定 `de-DE,en-US,zh-Hans → en`、`de-DE,fr-FR → zh-Hans` 等边界。

**取舍：** 不将偏好直接保存成当前解析语言，否则“跟随系统”会退化为固定语言；不为这个 UI 偏好引入新的业务配置文件或 iCloud 同步。

### 3. 资源查询与视图环境协同，避免只有部分界面切换

SwiftUI 层注入有效 `locale`，同时由语言上下文提供明确的资源 Bundle 和资源查询入口。普通 `String`、模型显示名、菜单、窗口标题和 AppKit/UIKit 自有文案必须经该入口取值，不能假设设置 SwiftUI 环境会更新已计算的字符串。

Apple 明确指出 `String(localized:..., locale:)` 的 `locale` 仅用于插值格式，不决定资源查询语言。带 `localizations:` 参数的 `Bundle.localizedString(forKey:value:table:localizations:)` 要求 macOS 15.4 / iOS 18.4，高于本项目部署基线（macOS 14 / iPadOS 17），MUST NOT 作为实现路径。资源查询入口固定为 `LocalizedTextResolver.resolve(key:table:descriptor:)`，采用基线可用的公开 API 组合：先用 `Bundle.preferredLocalizations(from:forPreferences:)` 做语言家族匹配并显式兜底 `zh-Hans`，再取对应 `xx.lproj` 子 Bundle（`path(forResource:ofType:)` + `Bundle(path:)`），以其 `localizedString(forKey:value:table:)` 查显式 table（`Localizable` 或 `Messages`）；子 Bundle 缺失或查找未命中时再以 `zh-Hans` 重复同一过程，两次均未命中则返回内置的简体中文通用错误。解析器在取模板前先校验 descriptor 的参数名、数量与 `kind`；模板与参数的组装使用 stringsdict 兼容的本地化感知格式化（复数变体按官方 stringsdict 机制由 `Text`、`String.localizedStringWithFormat` 等等效 API 触发），绝不将用户参数作为模板。静态 Swift 键继续使用 `String(localized:)`/`Text(LocalizedStringKey)` 的原生类型化插值；动态 descriptor code 无法走 `String(localized:)` 的静态字面量路径，其类型安全由解析器的 descriptor `kind` 校验承担，参数与模板不符时返回通用错误资源。实施前先以 macOS 与 iPadOS XCTest 编译并运行最小验证路径，覆盖：显式语言查找（`en` 与 `zh-Hans` 在相反系统语言下均从指定 table 取值）、动态 code 触发复数变体（0/1/2/大数量）、参数类型不符时返回通用错误、含百分号/引号/换行的参数不被二次解释。任一项验证失败，提案必须修订（资源格式或 resolver 方案）后才可继续实施，不能临时引入私有或全局 hook，也不能在实施中临时决定。

所有 Scene 共享同一语言上下文，原生菜单按打开时语言创建；应用管理的现有窗口标题由对应桥接更新。错误、Toast、状态标签、启动错误与日志事件应保存描述符/参数，在呈现时解析，不在后台操作开始时固定译文。必须向两端 Preview 与 XCTest 显式注入语言，避免依赖开发机器默认语言。

禁止使用 `.id(language)` 重建根视图强制刷新，因为这可能销毁终端、传输、编辑状态。终端、会话及传输 store 保持身份不变。系统托管且已显示的菜单/弹窗在下一次打开更新应用自有文案；系统自有按钮及第三方界面不保证遵从应用内覆盖。

**取舍：** 不 swizzle `Bundle.main`，不修改私有全局语言配置，不通过重启应用或重建工作区换取切换效果。

### 4. Rust/FFI 以结构化描述覆盖全部程序自定义错误

在 `panda-core` 定义稳定、语言无关的消息描述，包含语义消息标识、类型化安全参数以及可选的原始技术详情。其跨 FFI 的唯一 wire schema 为 `MessageDescriptorRecord { schema_version: u16, code: String, parameters: Vec<MessageParameterRecord>, technical_detail: Option<String> }`；参数记录为 `MessageParameterRecord { name: String, kind: MessageParameterKind, string_value: Option<String>, int_value: Option<i64>, uint_value: Option<u64>, bool_value: Option<bool> }`，其中 `kind` 是 `string/int/uint/bool` 闭集，且恰有与 `kind` 对应的一个值。`code` 使用小写点分语义键（如 `error.auth_failed`），参数名使用 ASCII 小写蛇形命名、在单个描述中唯一且按名称排序；`schema_version=1` 时未知字段、重复参数、非法 code 或值/种类不一致均为契约错误，不能静默显示为业务文案。新增参数只能以新 code 或新 schema 版本发布，已发布 code 的参数名、类型和安全级别不可改变。

业务 `Error`、连接失败分类、传输失败、终态原因在来源处生成描述；FFI 的未初始化、未知句柄等适配层错误复用同一 code 清单。`technical_detail` 只承载既有脱敏后、不可本地化的外部诊断，不能重复程序固定说明，也不能作为资源参数；其展示须由调用方显式选择。Swift 只按 descriptor 映射资源和呈现，不重新实现错误分类、参数提取、重试或安全判断。

实施审计包含所有程序自定义错误变体及固定包装说明，包括 `#[error(...)]`、`format!`、`to_string()` 进入兜底的上下文。程序定义的“读取配置失败”须对应资源；底层 `Permission denied`、异常链及堆栈保持原文并继续脱敏。所有自定义消息均有资源和测试，不能只遍历现有 `PandaError` 专用变体而忽略已经被压平的校验/存储错误。

保留既有 `PandaError` 变体与函数签名，不能通过修改其关联值形状或进程全局“最近一次错误”来偷渡 descriptor：前者会破坏已生成的 Swift 模式匹配，后者在并发连接下无法正确关联。所有可从生产 UI 到达且可能向用户呈现失败的既有 `Result<_, PandaError>` 调用 SHALL 逐项新增并行 `*_v2` 接口；每个 v2 接口以同一次调用返回的、带 `MessageDescriptorRecord` 的专用成功/失败结果 record 或 enum 表达失败，保持同步外观和现有会话所有权。迁移前须以 Swift 调用图和全部 FFI 导出双向盘点：每项要么登记 v2 入口，要么登记不可从生产 UI 到达的可复核依据与回归测试，禁止按模块或入口组默认豁免。旧接口只保留给兼容调用且新 UI 不得消费其最终文本。迁移矩阵在 proposal.md 中作为评审输入维护，逐项列出旧入口/字段、v2 入口或 record、结果类型、Swift 切换点与兼容期限；实现 MUST 与矩阵一致，实施中新发现的入口先补入矩阵再迁移。`Core(String)` 仅作为旧接口兼容及真正外部原文兜底，不得为恢复消息类别解析其中文或英文内容。

当前依赖纯文本 `ConnectionFailureRecord.title/detail` 的路径迁移到 descriptor，旧接口仅用于兼容，不再作为新界面的提示来源。消息清单为唯一声明输入：包含 code、参数模式以及仅供旧接口生成的 `legacy_wire_text`。后者是迁移前每个旧接口可观察输出的逐字基线，可能是英文、简体中文或二者混合；它不是 UI 翻译，也不得从 `zh-Hans` 或 `en` catalog 任选其一派生。先以迁移前回归夹具导入该字段并锁定逐字等价，再由仓库的确定性脚本生成已提交的只读 Rust 兼容表；UI catalog 与兼容表仅共享 code 和参数模式，不共享“显示语言即兼容文本”的假设。普通 `cargo build/test` 只能读取该生成物，绝不调用 Xcode、解析 `.xcstrings` 或联网；专用验证命令在具备工具链时重新生成并要求 `git diff --exit-code`，并校验生成表、消息清单及两份 catalog 的 code/参数模式完全一致。生成器版本、输入路径、输出路径和验证命令必须写入任务与开发文档；生成物缺失或漂移即失败，不能回退到手写文本。`Debug`、异常链和底层依赖 `Display` 不承担用户本地化，不需翻译。

通过“程序消息清单 ↔ 中英资源”的键、参数模式检查保证穷尽性；未知未来标识才允许通用回退。原始详情不得包含凭据、私钥材料或既有规范禁止披露的完整私钥路径。

**取舍：** 不将中文 `to_string()` 与另一份英语 `to_string()` 作为业务契约；不在 Rust 设置进程全局语言，以免并发任务缓存不同语言或产生锁竞争。

### 5. 日志事件与原始诊断分离，文件不受显示语言影响

扩展 core 日志条目为可选结构化事件描述加既有原始诊断文本。应用自己生成的连接/配置/传输提示改用事件标识与安全参数；原始异常、底层依赖错误和历史文本继续走兼容通道。UI 在展示已有结构化条目时按当前语言解析，所以切换无需清空日志。

三层表示关系固定如下，避免实现时各层漂移：

- **内存与 FFI（权威表示）**：core `LogEntry` 增加与 `MessageDescriptorRecord` 同构的可选描述符字段；FFI 新增 `log_event(descriptor: MessageDescriptorRecord)` 事件写入入口（写入前执行 schema 校验，非法即拒绝），新增 `log_entries_v2` 返回携带 `descriptor: Option<MessageDescriptorRecord>` 的条目 record；不修改既有 `LogEntryRecord` 的字段形状，`log_write` 保留为原始诊断兼容通道。
- **兼容镜像**：结构化事件的 `message` 字段承载与文件一致的 canonical JSON 镜像，仅供只读外层四段的旧工具与调试消费；UI MUST 仅依据 descriptor 呈现，MUST NOT 解析 `message` 或其中的 JSON 恢复事件内容。
- **文件（持久化表示）**：canonical JSON 仅是文件层的序列化形式，不是内存或 FFI 的权威承载；写入路径从描述符序列化，读取回放的解析器遇到未知 `v` 按下文规则降级。

结构化事件写入的拒绝规则具体化为可测试契约：单条结构化事件序列化后的 `消息` 字段长度上限为 **8192 字节**，作为固定公开常量随实现提交，运行时不可变，测试按常量断言边界（8191/8192/8193）；拒绝写入时以固定 code `log.event_rejected`（登记于消息清单与 `Messages` catalog）写入诊断事件，参数为 `reason`（`invalid_descriptor` / `duplicate_param` / `unrepresentable_value` / `too_large`）与 `limit_bytes`，`too_large` 时另含 `size_bytes`，MUST NOT 携带被拒原文的任何片段。

文件保留 `[ISO8601] [级别] [模块] 消息` 外层格式；结构化消息的 `消息` 字段使用版本化、单行的 canonical JSON 对象：`{"v":1,"code":"…","params":{…},"detail":"…"}`。键顺序固定为 `v/code/params/detail`，`params` 以参数名升序，所有字符串按 JSON 转义，控制字符、换行和分隔符绝不以原始字节写入；数值和布尔值使用 JSON 原生类型。`detail` 缺失时省略，且继续遵守脱敏规则。写入前拒绝非法 descriptor、重复参数、不可表示值和超过单条长度上限（上文固定 8192 字节常量）的事件，并以不含原值的 `log.event_rejected` 诊断记录失败；不得截断后伪造一个有效事件。事件标识、错误类别和参数足以保留排障语义；UI 显示可关联的译文。旧格式原始条目仍按原样写入/展示。轮转、容量、顺序、清除行为保持不变。

`v=1` 的 JSON schema、示例和解析 fixture SHALL 随实现提交；只依赖外层四段的既有工具继续可用，而将 `消息` 解析为自然语言的工具必须按 schema 升级。发布说明必须指出新结构化事件的消息字段不再是自然语言，旧文件不重写；解析器遇到未知 `v` 时保留该消息原文并报告不含敏感值的诊断，不得猜测解析。

这会改变新结构化事件的消息正文，但不修改旧文件，也不改变外层格式。测试必须覆盖文件稳定性、两种语言下相同事件的关联，以及异常/依赖原文不被翻译。

**取舍：** 不重新解析/翻译历史日志，不让后台 Rust 日志生产依赖 Swift 主线程或 Apple 资源加载。

### 6. 翻译完整性与 TDD 验收

实施前建立可执行文案清单与排除清单，按提示出口追踪来源而非仅扫描汉字；同时检查英文、字符串插值、原生控件、动态 `Text(String)`、错误包装和无障碍文案。预览/演示数据中的界面说明纳入翻译，模拟主机名等业务数据不翻译。审计以受版本控制的清单为输入，并由 `scripts/check-localization-completeness` 作为统一 CI 入口执行：该入口组合 catalog JSON 完整性/参数模式检查、Swift 提示出口检查和 Rust/FFI message code 清单检查。生产 Swift 文案只能经指定资源查询入口进入 `Text`、菜单、原生控件、无障碍和提示 API；生产 Rust/FFI 固定用户说明只能以 message code 创建。排除项逐条写明文件、行/符号、数据来源和理由，且测试校验排除目标仍是原始数据或纯开发诊断。扫描器允许保守地报出待人工确认项，但不得用整个目录、语言特征或未覆盖代码作为排除；新增命中或清单/资源/参数模式不一致均使 CI 失败。

先写失败测试再实施各批迁移：

- Rust：全部程序自定义错误/上下文、原始异常分离、描述参数、安全处理、日志事件及兼容接口。
- Swift：语言匹配、持久化、明确 Bundle 选择、键回退、数量/时长、异步失败呈现时语言及多窗口同步。
- 资源：中英键与必要变体齐全、翻译状态完成、占位符类型一致、程序消息清单无遗漏。最终人工检查措辞与安全语义，不能以“译文不等于 key”替代翻译质量审查。
- UI：macOS 与 iPadOS 分别检查中文、英文、系统跟随、无支持语言、手动覆盖，覆盖菜单/窗口/弹窗及活动连接/编辑状态保护。

资源和错误映射清单覆盖率要求 100%；新增纯逻辑所有正常/意外/边界分支覆盖；Rust 总体继续执行 `lines >= 95%` 且 `regions >= 95%`，不得通过扩大排除目录让门禁通过。所有交付译文必须完成，而不是只建立翻译基础设施。

### 官方依据与可行性

- [String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog.md)：支持集中资源、构建提取、多语言、复数及设备变体，适合现有 Xcode 16 工程；不使用文档中新版本独有扩展。
- [准备待翻译文本](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation.md)：SwiftUI 本地化类型、普通字符串本地化、传参上下文和 table/bundle 选择；也说明单纯自动提取不能覆盖非本地化 API 路径。
- [String 本地化初始化](https://developer.apple.com/documentation/swift/string/init(localized:table:bundle:locale:comment:).md)：`locale` 影响插值而非资源语言，适用版本早于项目部署基线。
- [SwiftUI locale](https://developer.apple.com/documentation/swiftui/environmentvalues/locale.md)：视图当前 locale 的公开环境入口；不将此说明扩大为所有原生窗口/缓存字符串自动更新的保证。
- [Bundle 首选本地化](https://developer.apple.com/documentation/foundation/bundle/preferredlocalizations(from:forpreferences:).md)：使用 BCP 47 首选列表；无匹配仍返回候选，需产品规则显式兜底简体中文。
- [Bundle.localizedString(forKey:value:table:localizations:)](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:localizations:).md)：该重载要求 macOS 15.4 / iOS 18.4，高于本项目部署基线，故排除；基线内改用 `.lproj` 子 Bundle + [localizedString(forKey:value:table:)](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:).md)。
- [Localizing strings that contain plurals](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals.md)：复数变体由 stringsdict 机制定义，经 `Text`、`NSLocalizedString` 及等效本地化感知格式化 API 触发；这是动态 descriptor code 复数路径的官方依据，最终以任务 2.2b 的双端验证为准。
- [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults.md)：本机非敏感偏好、异步持久化与隐私清单要求；不改变项目凭据存储约定。

上述官方能力覆盖所需资源与语言机制，无需增加第三方依赖。资源查询封装、消息描述与兼容表导出属于本项目集成代码，需要先由测试验证；若实测公开 API 不能满足跨窗口更新，按官方文档 → 社区讨论顺序查证后再修订设计，不采用私有 hook。

## Risks / Trade-offs

- [动态文本遗漏] → 从提示出口反向追踪，结合程序错误穷举、双语资源检查和人工逐页审计，不能只搜索汉字。
- [平台语言匹配隐式兜底] → 对不支持列表显式回退 `zh-Hans`，测试后续支持语言优先于默认值。
- [英文更长导致截断] → 在 macOS 设置固定尺寸、窄侧栏、iPad 横竖屏检查布局，允许自适应和换行，不裁掉安全信息。
- [切换引发重连或清空编辑] → 不重建根视图，验证对象/句柄身份、终端缓冲、传输进度与未提交输入。
- [兼容文本与资源漂移] → 以消息清单中的 `legacy_wire_text` 锁定迁移前逐字输出，UI catalog 仅按同一 code/参数模式关联；生成兼容表与迁移前夹具双向校验，任何公开签名变更需另行评审。
- [原始异常包含秘密] → 不翻译不等于直接泄露，沿用安全过滤，避免资源参数和日志携带凭据。
- [用户误以为第三方弹窗也已切换] → 设置说明只承诺应用自有内容；系统托管界面沿用系统行为。
- [并行提案产生新提示] → 实施与归档前重新扫描活动变更交叉点，要求新增提示也进入清单。

## Migration Plan

1. 评审本提案后，以测试夹具建立文案/错误清单和双语完整性失败测试；保留本轮提案未实施状态。
2. 先完成语言上下文、原生资源与打包验证（含 2.2a/2.2b 的显式语言查找与动态 code 复数/插值可行性验证，验证不过先修订本设计），再按 Rust/FFI 描述、界面模块、日志、原生窗口分批执行 Red → Green → Refactor。
3. 每个模块同时迁移资源及中英译文，不留占位译文；旧数据、历史日志、用户自定义名称原样保留。
4. 运行 Rust 测试/覆盖率、双端 Swift 测试；涉及 FFI 按 `build-rust.sh → xcodegen → 双端 xcodebuild` 重建并做实际语言切换验收。
5. 完整交付后合并规范增量并归档，不在本次提案阶段修改主规范或生产代码。

回滚以撤回实现变更恢复旧呈现为单位，不删除用户配置、凭据或日志。新增语言偏好可留存但旧版本忽略；新旧日志兼容通道需保证旧工具仍可读取外层格式。若部分迁移尚未完成，不将语言切换入口作为完成版本发布。
