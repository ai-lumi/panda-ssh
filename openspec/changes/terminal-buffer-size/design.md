## Context

当前终端基于 SwiftTerm，`Terminal` 类型内部维护回滚缓冲区。SwiftTerm 的 `Terminal` 初始化时接受 `options` 参数，其中可配置 `scrollback` 行数。见 proposal.md - Why。

## Goals / Non-Goals

**Goals:**
- 暴露缓冲区行数配置到 Settings UI。
- 提供直观的内存估算，帮助用户理解行数与内存的关系。
- 新终端标签页即时应用配置。

**Non-Goals:**
- 不支持按主机单独设置。
- 不调整已打开终端的缓冲区大小。
- 不替代 SwiftTerm 的默认行为，仅覆盖初始化参数。

## Decisions

### 决策 1：配置持久化使用 `UserDefaults`

**选择：** 使用 `UserDefaults.standard` 存储 `terminalBufferLines` 整数值。

**理由：**
- 非敏感配置，无需钥匙串保护。
- `UserDefaults` 在 macOS/iPadOS 双端行为一致。
- 与现有设置（如未出现的其他偏好设置）保持一致。

### 决策 2：内存估算公式

**选择：** 优先使用已打开终端标签页的实际列数平均值；若无终端打开，则回退到默认终端宽度 80 列。

```
columns = 已打开终端的平均列数（若存在），否则 80
estimatedBytes = lines × columns × MemoryLayout<Cell>.size
```

**理由：**
- SwiftTerm 内部 `BufferLine` 由 `Cell` 数组构成；`Cell` 包含字符、属性、颜色等字段。
- 80 列为 PTY 分配的默认宽度，作为无终端时的保守估计。
- 若用户已打开终端，其实际列数比固定假设更准确。
- 估算为近似值（未计入 ANSI 属性、空行稀疏存储等优化），仅用于数量级参考。

**替代方案 1：** 固定 160 列。放弃原因：窗口缩放到很窄或很宽时偏离实际。
**替代方案 2：** 按每行实际已用字符数计算。放弃原因：设置页无缓冲区实例，无法遍历历史内容；且空行稀疏存储使逐行计算过于复杂。

### 决策 3：仅新标签生效

**选择：** 配置变更不追溯已打开终端。

**理由：**
- 避免运行时截断用户正在查看的历史内容，造成困惑。
- SwiftTerm 缓冲区大小通常在初始化时确定，运行时调整需重建内部数据结构，风险较高。
- 用户可关闭旧标签后重新打开以获得新配置。

### 决策 4：SettingsView 使用 Stepper + TextField 组合

**选择：** macOS 使用 `Stepper` 搭配 `TextField`；iPadOS 使用 `TextField` + 数字键盘。

**理由：**
- Stepper 适合微调，TextField 适合直接输入大数值。
- 需要在输入时实时触发内存估算更新。

## Risks / Trade-offs

- **[用户设置过大导致内存压力]** → 最大限制 100000 行 + 内存估算显示，提供数量级警示。
- **[SwiftTerm 内部 Cell 大小变化导致估算偏差]** → 估算为近似值，在 UI 文案中标注「约」。
- **[UserDefaults 在 macOS 与 iPadOS 间不共享]** → 本设置仅本地生效，与当前无 iCloud 同步的策略一致。
