//! 遥测、日志和连接健康检查 FFI 导出。

use crate::ffi_runtime::runtime;
use crate::PandaError;
use std::sync::Arc;

/// 回调只负责投递快照；调用方应切换到自己的 UI 执行器。
#[uniffi::export(callback_interface)]
pub trait ConnectionTelemetryObserver: Send + Sync {
    fn on_snapshot(&self, snapshot: ConnectionTelemetrySnapshotRecord);
}

#[derive(uniffi::Record)]
pub struct ConnectionTelemetrySnapshotRecord {
    pub revision: u64,
    pub records: Vec<ConnectionTelemetryRecord>,
}

impl From<panda_core::telemetry::TelemetrySnapshot> for ConnectionTelemetrySnapshotRecord {
    fn from(snapshot: panda_core::telemetry::TelemetrySnapshot) -> Self {
        Self {
            revision: snapshot.revision,
            records: snapshot.records.into_iter().map(Into::into).collect(),
        }
    }
}

#[uniffi::export]
pub fn connection_telemetry_snapshot() -> ConnectionTelemetrySnapshotRecord {
    panda_core::telemetry::global_registry()
        .versioned_snapshot()
        .into()
}

/// 句柄不被任务持有，释放最后一个句柄会结束等待并释放观察者。
#[derive(uniffi::Object)]
pub struct ConnectionTelemetrySubscription {
    task: tokio::task::AbortHandle,
}

#[uniffi::export]
impl ConnectionTelemetrySubscription {
    pub fn cancel(&self) {
        self.task.abort();
    }
}

impl Drop for ConnectionTelemetrySubscription {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[uniffi::export]
pub fn connection_telemetry_subscribe(
    observer: Box<dyn ConnectionTelemetryObserver>,
) -> Arc<ConnectionTelemetrySubscription> {
    let mut subscription = panda_core::telemetry::global_registry().subscribe();
    let task = runtime().spawn(async move {
        loop {
            observer.on_snapshot(subscription.next_snapshot().await.into());
        }
    });
    Arc::new(ConnectionTelemetrySubscription {
        task: task.abort_handle(),
    })
}

// ---------------------------------------------------------------------------
// Connection telemetry types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStateEnum {
    Connecting,
    Active,
    Idle,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshConnectionStateEnum {
    Connecting,
    Authenticated,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HealthStateEnum {
    Unknown,
    Healthy,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelStateEnum {
    Open,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelKindEnum {
    Shell,
    Sftp,
    Exec,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelTelemetryRecord {
    pub id: u64,
    pub kind: ChannelKindEnum,
    pub state: ChannelStateEnum,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub received_bytes: u64,
    pub sent_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionTelemetryRecord {
    pub id: u64,
    pub host_id: String,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub transport_state: ConnectionStateEnum,
    pub ssh_state: SshConnectionStateEnum,
    pub health_state: HealthStateEnum,
    pub last_health_check_at_ms: Option<u64>,
    pub received_bytes: u64,
    pub sent_bytes: u64,
    pub receive_bytes_per_second: u64,
    pub send_bytes_per_second: u64,
    pub last_error: Option<String>,
    pub channels: Vec<ChannelTelemetryRecord>,
}

impl From<panda_core::telemetry::HealthState> for HealthStateEnum {
    fn from(value: panda_core::telemetry::HealthState) -> Self {
        match value {
            panda_core::telemetry::HealthState::Unknown => Self::Unknown,
            panda_core::telemetry::HealthState::Healthy => Self::Healthy,
            panda_core::telemetry::HealthState::Unavailable => Self::Unavailable,
        }
    }
}

impl From<panda_core::telemetry::ChannelSnapshot> for ChannelTelemetryRecord {
    fn from(value: panda_core::telemetry::ChannelSnapshot) -> Self {
        use panda_core::telemetry::{ChannelKind, ChannelState};
        Self {
            id: value.id,
            kind: match value.kind {
                ChannelKind::Shell => ChannelKindEnum::Shell,
                ChannelKind::Sftp => ChannelKindEnum::Sftp,
                ChannelKind::Exec => ChannelKindEnum::Exec,
            },
            state: match value.state {
                ChannelState::Open => ChannelStateEnum::Open,
                ChannelState::Closed => ChannelStateEnum::Closed,
                ChannelState::Failed => ChannelStateEnum::Failed,
            },
            created_at_ms: value.created_at_ms,
            last_activity_at_ms: value.last_activity_at_ms,
            received_bytes: value.received_bytes,
            sent_bytes: value.sent_bytes,
        }
    }
}

impl From<panda_core::telemetry::ConnectionSnapshot> for ConnectionTelemetryRecord {
    fn from(value: panda_core::telemetry::ConnectionSnapshot) -> Self {
        use panda_core::telemetry::{SshState, TransportState};
        Self {
            id: value.id,
            host_id: value.host_id,
            address: value.address,
            owner_kind: value.owner_kind,
            owner_id: value.owner_id,
            created_at_ms: value.created_at_ms,
            last_activity_at_ms: value.last_activity_at_ms,
            transport_state: match value.transport_state {
                TransportState::Connecting => ConnectionStateEnum::Connecting,
                TransportState::Active => ConnectionStateEnum::Active,
                TransportState::Idle => ConnectionStateEnum::Idle,
                TransportState::Closed => ConnectionStateEnum::Closed,
                TransportState::Failed => ConnectionStateEnum::Failed,
            },
            ssh_state: match value.ssh_state {
                SshState::Connecting => SshConnectionStateEnum::Connecting,
                SshState::Authenticated => SshConnectionStateEnum::Authenticated,
                SshState::Closed => SshConnectionStateEnum::Closed,
                SshState::Failed => SshConnectionStateEnum::Failed,
            },
            health_state: value.health_state.into(),
            last_health_check_at_ms: value.last_health_check_at_ms,
            received_bytes: value.received_bytes,
            sent_bytes: value.sent_bytes,
            receive_bytes_per_second: value.receive_bytes_per_second,
            send_bytes_per_second: value.send_bytes_per_second,
            last_error: value.last_error,
            channels: value
                .channels
                .into_iter()
                .map(ChannelTelemetryRecord::from)
                .collect(),
        }
    }
}

// ---------------------------------------------------------------------------
// Connection lifecycle
// ---------------------------------------------------------------------------

/// 返回当前进程内的连接监控快照。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionLifecycleRecord {
    pub connection_id: u64,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub reason: String,
    pub is_error: bool,
}

impl From<panda_core::telemetry::LifecycleEvent> for ConnectionLifecycleRecord {
    fn from(event: panda_core::telemetry::LifecycleEvent) -> Self {
        Self {
            connection_id: event.connection_id,
            address: event.address,
            owner_kind: event.owner_kind,
            owner_id: event.owner_id,
            reason: event.kind.description().into(),
            is_error: event.kind.is_error(),
        }
    }
}

/// 由应用级日志桥接器消费；监控窗口不消费队列。
#[uniffi::export]
pub fn connection_lifecycle_drain() -> Vec<ConnectionLifecycleRecord> {
    panda_core::telemetry::global_registry()
        .drain_events()
        .into_iter()
        .map(Into::into)
        .collect()
}

#[uniffi::export]
pub fn connection_telemetry_list() -> Vec<ConnectionTelemetryRecord> {
    panda_core::connection_registry::global_registry().prune();
    panda_core::telemetry::global_registry()
        .snapshot()
        .into_iter()
        .map(ConnectionTelemetryRecord::from)
        .collect()
}

/// 对既有连接执行无命令的 SSH 通道探测。
#[uniffi::export]
pub fn connection_health_check(connection_id: u64) -> Result<HealthStateEnum, PandaError> {
    runtime().block_on(async {
        Ok(panda_core::connection_registry::global_registry()
            .check_health(connection_id)
            .await?
            .into())
    })
}

// ---------------------------------------------------------------------------
// Connection failure classification
// ---------------------------------------------------------------------------

/// 连接失败分类（FFI 友好枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FailureCategoryEnum {
    Timeout,
    AuthFailed,
    MissingCredential,
    HostKeyMismatch,
    Other,
}

/// 连接失败的结构化记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionFailureFFIRecord {
    pub category: FailureCategoryEnum,
    pub title: String,
    pub detail: String,
}

/// 将 core 的失败类别映射为 FFI 枚举。
/// 转换与映射分离：映射臂（含经错误码表不可达的 HostKeyMismatch）可被直接单测。
fn map_failure_category(category: panda_core::FailureCategory) -> FailureCategoryEnum {
    match category {
        panda_core::FailureCategory::Timeout => FailureCategoryEnum::Timeout,
        panda_core::FailureCategory::AuthFailed => FailureCategoryEnum::AuthFailed,
        panda_core::FailureCategory::MissingCredential => FailureCategoryEnum::MissingCredential,
        panda_core::FailureCategory::HostKeyMismatch => FailureCategoryEnum::HostKeyMismatch,
        panda_core::FailureCategory::Other => FailureCategoryEnum::Other,
    }
}

/// 将错误码分类为连接失败记录。
#[uniffi::export]
pub fn connection_failure_classify(error_code: String) -> ConnectionFailureFFIRecord {
    let error = match error_code.as_str() {
        "Timeout" => panda_core::Error::Timeout,
        "AuthFailed" => panda_core::Error::AuthFailed,
        "MissingPassphrase" => panda_core::Error::MissingPassphrase,
        "CredentialProtectionKeyRequired" => panda_core::Error::CredentialProtectionKeyRequired,
        "CredentialUnlockFailed" => panda_core::Error::CredentialUnlockFailed,
        "InvalidCredentialFile" => panda_core::Error::InvalidCredentialFile,
        "Cancelled" => panda_core::Error::Cancelled,
        "ShellSessionClosed" => panda_core::Error::ShellSessionClosed,
        other => panda_core::Error::Other(other.to_string()),
    };
    let record = panda_core::connection_failure_classify(&error);
    ConnectionFailureFFIRecord {
        category: map_failure_category(record.category),
        title: record.title,
        detail: record.detail,
    }
}

// ---------------------------------------------------------------------------
// Logger API
// ---------------------------------------------------------------------------

/// 日志级别（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevelEnum {
    Debug,
    Info,
    Warning,
    Error,
}

/// 日志条目（FFI 记录）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct LogEntryRecord {
    pub id: u64,
    pub timestamp: String,
    pub level: LogLevelEnum,
    pub module: String,
    pub message: String,
}

/// 写入一条日志。
#[uniffi::export]
pub fn log_write(level: LogLevelEnum, module: String, message: String) {
    let core_level = match level {
        LogLevelEnum::Debug => panda_core::logger::LogLevel::Debug,
        LogLevelEnum::Info => panda_core::logger::LogLevel::Info,
        LogLevelEnum::Warning => panda_core::logger::LogLevel::Warning,
        LogLevelEnum::Error => panda_core::logger::LogLevel::Error,
    };
    panda_core::logger::global_logger().log(core_level, &module, &message);
}

/// 获取最近的日志条目（按时间倒序）。
#[uniffi::export]
pub fn log_entries(limit: u32) -> Vec<LogEntryRecord> {
    panda_core::logger::global_logger()
        .entries(limit as usize)
        .into_iter()
        .map(|e| LogEntryRecord {
            id: e.id,
            timestamp: e.timestamp,
            level: match e.level {
                panda_core::logger::LogLevel::Debug => LogLevelEnum::Debug,
                panda_core::logger::LogLevel::Info => LogLevelEnum::Info,
                panda_core::logger::LogLevel::Warning => LogLevelEnum::Warning,
                panda_core::logger::LogLevel::Error => LogLevelEnum::Error,
            },
            module: e.module,
            message: e.message,
        })
        .collect()
}

/// 清空日志缓冲。
#[uniffi::export]
pub fn log_clear() {
    panda_core::logger::global_logger().clear();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "tests/ffi_telemetry_tests.rs"]
mod tests;
