## Context

当前 `panda-core` 的批量下载路径（`execute_batch_download`）使用 `tokio::fs::create_dir_all`，可递归创建本地目录并忽略已存在目录；而批量上传路径（`execute_batch_upload`）调用 `SftpClient::create_dir`，其底层是 russh-sftp 的单层 `mkdir`，既不递归创建父目录，也不忽略已存在目录。两端行为不对称导致目录上传在远端父目录缺失时失败，并产生难以定位的 `No such file` 错误。

## Goals / Non-Goals

**Goals:**
- 统一上传与下载的目录创建语义：批量上传 SHALL 递归创建远端目录并忽略已存在目录。
- 批量传输错误信息 SHALL 同时暴露本地源路径与远端目标路径。
- 通过 Rust 单元测试与 FFI 集成测试覆盖父目录缺失、目录已存在、嵌套目录三种场景。

**Non-Goals：**
- 不修改单文件上传接口 `sftp_upload` 的语义。
- 不改动覆盖确认与冲突决策逻辑。
- 不深究 russh-sftp 错误 Display 格式本身，只在错误收集层补充路径信息。

## Decisions

### Decision 1：在 `SftpClient` 新增 `create_dir_all` 方法

在 `crates/panda-core/src/sftp.rs` 中新增 `pub async fn create_dir_all(&self, path: &str) -> Result<()>`，手动按 `/` 切分路径并逐层调用 `self.session.create_dir()`。

**理由：**
- russh-sftp 没有直接提供 `mkdir -p` 接口，业务层需要封装。
- 与下载侧的 `tokio::fs::create_dir_all` 形成语义对称，便于维护。

**替代方案：**
- 直接在 `execute_batch_upload` 中内联递归逻辑。 rejected，因为这会污染批量传输逻辑，且其他可能使用递归目录创建的地方无法复用。

### Decision 2：`create_dir_all` 忽略 `StatusCode::Failure` 表示的已存在错误

对每一层目录调用 `create_dir` 时，捕获 `russh_sftp::client::error::Error::Status(status)`：
- 若 `status.status_code == StatusCode::Failure` 且 message 包含 `"already exists"`（或类似语义），视为成功。
- 若 `status.status_code == NoSuchFile` 且当前正在创建的是中间层，说明上层尚未创建，继续向上创建父目录即可。

**理由：**
- OpenSSH 等服务器对已存在目录通常返回 `SSH_FX_FAILURE` 并附带 `"already exists"` 消息；必须忽略该状态，否则已存在目录会被误判为失败。
- 保持与 `tokio::fs::create_dir_all` 的行为一致。

**替代方案：**
- 在上传前先用 `metadata` 探测目录是否存在，再决定是否创建。rejected，因为这会增加一次额外 RTT，且同样存在竞态条件。

### Decision 3：错误信息格式为 `"{source} -> {destination}: {error}"`

在 `execute_batch_upload` 与 `execute_batch_download` 中，统一将错误信息从 `"{}: {}"` 改为 `"{} -> {}: {}"`，分别填入本地源路径、远端目标路径与底层错误。

**理由：**
- 同时暴露两端路径，用户可立即定位失败项。
- 下载侧一并修改，保持批量传输两端错误格式一致。

**替代方案：**
- 仅修改上传侧。rejected，因为这会导致两端错误格式不一致，影响日志与 UI 展示。

## Risks / Trade-offs

- **[Risk] 不同 SFTP 服务器对已存在目录返回的消息文本不一致** → Mitigation：同时匹配 `StatusCode::Failure` 与消息中的 `"already exists"`、`"File exists"`、`"exists"` 等常见关键字；若无法可靠匹配，可进一步降级为对 `StatusCode::Failure` 也忽略（因为批量上传场景下，创建目录失败通常意味着目录已存在或权限不足，而权限不足会在后续文件写入时再次暴露）。
- **[Risk] 递归创建目录增加 SFTP 请求次数** → Mitigation：仅在父目录缺失时逐层创建；常见场景（目标父目录已存在）只需创建最底层目录，额外开销与原来相同。
- **[Risk] 路径切分对 Windows 风格路径不敏感** → Mitigation：SFTP 协议路径统一为正斜杠 `/`，按 `/` 切分即可。

## Migration Plan

无需数据迁移。修复后，新上传的目录自动具备递归创建能力；已有失败任务的重试将按新逻辑执行。
