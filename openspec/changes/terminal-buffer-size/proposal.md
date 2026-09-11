> 版本归属：下一版本（版本号待定）｜实施状态：未开始。
> 2026-09-11 用户确认纳入，完整清单见[下一版本范围](../../next-release.md)。

## Why

当前 SwiftTerm 终端使用默认缓冲区大小，在长时间运行产生大量输出的场景（如日志跟踪、编译）下，旧内容被过早丢弃，用户无法回溯查看。需要允许用户按行数配置缓冲区大小，并在设置时直观显示对应内存占用，避免误设导致 OOM。

## What Changes

- 新增「终端缓冲区行数」设置项：用户可在 Settings 中输入缓冲区最大保留行数（默认 10000，范围 1000–100000）。
- 自动内存估算：设置界面根据行数实时计算并显示预估内存占用（基于平均行宽与 SwiftTerm 内部字符单元大小）。
- 终端初始化时应用配置：每个新打开的终端标签页读取当前设置值初始化 `TerminalView` 的缓冲区。
- 已打开的终端标签页不追溯调整大小，仅新标签生效，避免运行时截断正在查看的内容。

## Non-goals

- 本期不支持按主机单独设置缓冲区大小，仅全局设置。
- 不实现运行时动态扩展/收缩已打开终端的缓冲区。
- 不替代 SwiftTerm 的默认回滚机制，仅在现有机制上暴露可配置参数。

## Capabilities

### New Capabilities
- `terminal-buffer-size`: 终端缓冲区行数配置、内存估算公式、设置持久化与终端初始化应用。

### Modified Capabilities
- `shell-terminal`: 补充缓冲区大小初始化要求；终端初始化时 MUST 读取用户配置并设置对应回滚行数。

## Impact

- SwiftUI：SettingsView 新增「终端缓冲区」Section（含行数输入、内存估算显示）。
- SwiftTerm：通过 `TerminalView`/`Terminal` 的公开 API 设置 `scrollback` 或等效参数。
- 配置持久化：与现有设置一致，暂存于 `UserDefaults`（非敏感配置）。
- macOS/iPadOS 双端共享同一设置逻辑。
