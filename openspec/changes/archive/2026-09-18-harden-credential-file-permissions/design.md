## Context

见 proposal.md。当前凭据存储复用通用的临时文件加 rename 写入函数；它以
`std::fs::write` 建立临时文件，文件最终权限取决于进程 umask。配置目录由 FFI
初始化入口递归创建，未对专属目录或既有凭据的模式作校验。

## Goals / Non-Goals

**Goals:**

- 在 Unix 将凭据目录与 `credentials.toml` 的权限收紧到所有者专用。
- 确保临时文件在首次写入任何秘密前已经具备限制性权限。
- 不改变凭据格式、加密/解密流程或普通配置文件的访问策略。
- 让新增逻辑在非 Unix 目标上零行为变化且可编译。

**Non-Goals:**

- 不递归修改调用方传入路径的父目录，也不接管 App Group 容器的上级目录。
- 不将通用 `write_atomic` 的所有调用方一律改为 `0600`。
- 不承诺 Windows ACL 或其他非 Unix 平台的等价访问控制。

## Decisions

1. 为 `CredentialStore` 增加专属的私有原子写入路径，而非修改通用
   `write_atomic`。凭据是唯一确定包含秘密的调用方；收紧 hosts、groups、known_hosts
   的权限虽可能合理，但扩大了本次行为范围，留待独立评审。

2. Unix 临时文件使用不可预测名称与独占创建，并在打开后、写入前显式设为
   `0o600`。独占创建消除对既有文件或符号链接的跟随；创建模式消除新文件的可读
   窗口。写完后以 rename 替换目标，保留原子可见性。旧版固定临时文件以 unlink
   语义移除：即使它是符号链接，也只删除链接本身而不得跟随或影响链接目标。

   替代方案是在 `fs::write` 后调用 `set_permissions`。不采用：内容已经可能在
   宽松权限下落盘，且不保证重新使用的临时文件先被保护。

3. 由 `init_store` 在 macOS/Linux 等传入 Panda SSH 专属目录的 Unix 平台将目录
   收紧为 `0o700`，并在存在时将 `credentials.toml` 收紧为 `0o600`。iPadOS 的
   App Group 容器由系统权限与 entitlements 管理，初始化不得 chmod 容器根目录，
   但仍收紧凭据文件。保存凭据也再次保证目标文件权限，以覆盖旧安装和直接构造
   `CredentialStore` 的调用。

   替代方案是只在保存时收紧文件。它无法在启动到首次保存期间保护已有凭据，且不
   满足配置目录访问边界。

4. Unix 权限实现和断言均使用 `#[cfg(unix)]`；非 Unix 使用既有文件 API，不引入
   模拟 Unix mode 的依赖。

## Risks / Trade-offs

- [iPadOS 传入共享 App Group 容器] → 平台分支跳过目录 chmod，仅让系统 sandbox
  与 entitlements 管理容器访问；凭据文件仍单独收紧。
- [权限修改失败] → 返回 I/O 错误并不写入或初始化 stores，避免误报凭据已安全保存。
- [已有临时文件或目标是异常类型] → 通过独占创建拒绝复用；旧版保留临时路径仅用
  unlink 清理，不跟随链接或删除其目标。
- [移动到不支持 Unix mode 的目标] → 由条件编译排除 Unix API，并以目标检查验证。

## Migration Plan

发布后首次 `init_store` 将收紧已存在配置目录与凭据文件；每次后续保存再次保证
凭据权限。若发生回归，回退该变更不会改变 TOML 数据格式，但已收紧的 Unix 权限
不会自动放宽，用户仍可继续访问其自身数据。
