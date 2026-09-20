## Why

`credentials.toml` 可保存 SSH 密码和私钥口令，但当前原子写入依赖进程的
umask；在常见的 `022` 设置下，新文件会以其他本机用户可读的权限创建。配置
目录本身也未被限制访问。这违背了凭据仅应由当前用户读取的安全边界，需要在
凭据落盘路径上强制最小权限。

## What Changes

- 在 Unix 平台保证新建及更新后的 `credentials.toml` 为仅文件所有者可读写。
- 在 Unix 平台保证 Panda SSH 专属配置目录仅文件所有者可访问，并在初始化时
  修复已有目录和凭据文件的宽松权限。
- 保持凭据原子替换语义；临时文件在写入秘密前即使用限制性权限，避免将权限
  收紧放在写入之后产生的暴露窗口，并且不得跟随或复用既有临时文件链接。
- iPadOS 保留系统管理的 App Group 容器权限；仅 macOS/Linux 等传入 Panda SSH
  专属目录的 Unix 平台收紧目录模式。
- 非 Unix 平台维持现有文件写入行为和可编译性。

## Non-goals

- 不更改凭据的 TOML 格式、可选 AEAD 加密格式或保护密钥流程。
- 不修改 `hosts.toml`、`groups.toml`、`known_hosts`、日志或片段文件的权限策略。
- 不尝试改变用户指定的父目录、App Group 容器上级目录，或系统级访问控制策略。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `auth`: 本地凭据文件与 Panda SSH 专属配置目录的 Unix 文件权限要求。

## Impact

- `crates/panda-core`：为凭据文件提供仅限所有者访问的原子写入路径及 Unix
  权限测试。
- `crates/panda-ffi`：初始化配置目录时执行受限权限的创建/修复，并补充集成测试。
- macOS：限制同机其他用户读取本地保存的密码和私钥口令。
- iPadOS：保留 App sandbox 与 App Group 容器权限，只收紧凭据文件本身。
