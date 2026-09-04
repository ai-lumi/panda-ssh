## Context

现有构建脚本只生成 Apple Silicon 的 macOS Rust 库，且工程 Release 配置使用临时签名。参见 proposal.md 与对应规格增量。

## Goals / Non-Goals

**Goals:**

- 在单个 macOS Runner 上生成包含 `arm64`、`x86_64` macOS 静态库的 XCFramework，并令 Xcode Archive 生成 Universal App。
- 将测试、构建、ZIP/DMG 打包和 GitHub Release 上传置于同一可重复运行的工作流。
- 用脚本级测试锁定目标架构、无 Developer ID 构建选项和工作流发布门槛。

**Non-Goals:**

- 不引入签名证书、密钥、notarytool 凭据、自动更新服务或 Gitee 托管 Runner。
- 不为构建产物执行公证验证；无 Developer ID 的 App 不能通过该验证。

## Decisions

### GitHub Actions 使用 macOS 托管 Runner

工作流固定使用 GitHub 的 macOS Runner，而不是假设 Gitee 提供 macOS Runner。GitHub 已提供该运行环境；Gitee 可作为镜像或下载入口。备选方案是维护者自托管 Mac Runner，但会引入机器维护与凭据暴露面，不作为默认路径。

### 先合成 Universal 静态库，再创建 XCFramework

构建脚本分别编译 `aarch64-apple-darwin` 与 `x86_64-apple-darwin`，再使用 `lipo` 合成一个 macOS Universal 静态库并交给 `xcodebuild -create-xcframework`。`xcodebuild` 将同平台不同架构的独立静态库视为等价定义而拒绝创建 XCFramework；合成后可保留两个架构且满足工具约束。备选的独立 slice 方案经本机构建验证不成立。

### Archive 显式禁用签名，ZIP 与 DMG 均作为工件

Release Archive 传入 `CODE_SIGNING_ALLOWED=NO`，不依赖 CI Keychain；Xcode 仍可能产生不带团队身份的 ad-hoc 签名。ZIP 方便下载器校验与解压，DMG 提供 macOS 常见安装体验。备选的 PKG 不采用，因为它不改善无 Developer ID 体验且增加安装权限与维护成本。

### 先做文本契约测试，再做平台构建验证

测试先断言脚本、Xcode 配置和工作流的关键发布契约，再运行 Rust 测试与 Archive。文本测试不能证明 Universal 二进制，但可快速阻断配置回退；最终 Archive 与 `lipo`/`file` 检查承担二进制验证。

## Risks / Trade-offs

- [无 Developer ID App 被 Gatekeeper 拦截] → Release notes 明确右键打开流程；不建议关闭系统安全设置。
- [GitHub macOS Runner 或 Xcode 版本变化] → 固定 runner 标签，并在工作流中输出 Xcode 与 Rust 版本以便追溯。
- [Intel slice 缺失或 Xcode 未构建为 Universal] → CI 检查 XCFramework macOS slices 及 Archive 内可执行文件的两个架构。
- [第三方依赖下载失败] → 缓存 Cargo 依赖；失败时不发布。

## Migration Plan

1. 为脚本和工作流添加失败的契约测试。
2. 扩展 Rust 构建脚本与 Xcode Release 架构配置，使测试转绿。
3. 新增 GitHub Actions 工作流，运行测试、Archive、架构检查、打包及 Release 上传。
4. 本地执行测试与 Archive 验证；CI 首次运行后，在一台 Intel 与一台 Apple Silicon Mac 上验证安装（Validation）。

回滚方式为删除工作流并恢复构建脚本的 macOS 架构列表；不会影响已发布工件或用户数据。
