//! 跨平台 SSH 连接遥测。
//!
//! 这里只保存状态、时间与计数，不保存凭据、命令、终端输出或文件内容。

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RATE_WINDOW: Duration = Duration::from_millis(250);
const IDLE_AFTER_MS: u64 = 5_000;

/// 固定原因枚举，不允许把远端内容或原始错误串写入生命周期日志。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleKind {
    Connected,
    ShellExit,
    ExplicitClose,
    SocketEof,
    ReadError,
    WriteError,
    KeepaliveFailed,
    TransportError,
    Released,
}

impl LifecycleKind {
    pub fn description(self) -> &'static str {
        match self {
            Self::Connected => "连接成功",
            Self::ShellExit => "Channel 正常结束",
            Self::ExplicitClose => "显式关闭",
            Self::SocketEof => "Socket EOF",
            Self::ReadError => "Socket 读取失败",
            Self::WriteError => "Socket 写入失败",
            Self::KeepaliveFailed => "SSH keepalive 失败",
            Self::TransportError => "SSH 传输异常",
            Self::Released => "所有者释放",
        }
    }
    pub fn is_error(self) -> bool {
        matches!(
            self,
            Self::SocketEof
                | Self::ReadError
                | Self::WriteError
                | Self::KeepaliveFailed
                | Self::TransportError
        )
    }
}

#[derive(Debug, Clone)]
pub struct LifecycleEvent {
    pub connection_id: u64,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub kind: LifecycleKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportState {
    Connecting,
    Active,
    Idle,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SshState {
    Connecting,
    Authenticated,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthState {
    Unknown,
    Healthy,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelState {
    Open,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelKind {
    Shell,
    Sftp,
    Exec,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelSnapshot {
    pub id: u64,
    pub kind: ChannelKind,
    pub state: ChannelState,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub received_bytes: u64,
    pub sent_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionSnapshot {
    pub id: u64,
    pub host_id: String,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub transport_state: TransportState,
    pub ssh_state: SshState,
    pub health_state: HealthState,
    pub last_health_check_at_ms: Option<u64>,
    pub received_bytes: u64,
    pub sent_bytes: u64,
    pub receive_bytes_per_second: u64,
    pub send_bytes_per_second: u64,
    pub last_error: Option<String>,
    pub channels: Vec<ChannelSnapshot>,
}

struct ConnectionRecord {
    host_id: String,
    address: String,
    owner_kind: String,
    owner_id: String,
    created_at_ms: u64,
    last_activity_at_ms: u64,
    transport_state: TransportState,
    ssh_state: SshState,
    health_state: HealthState,
    last_health_check_at_ms: Option<u64>,
    received_bytes: u64,
    sent_bytes: u64,
    receive_bytes_per_second: u64,
    send_bytes_per_second: u64,
    rate_window_started: Instant,
    rate_window_received: u64,
    rate_window_sent: u64,
    last_error: Option<String>,
    channels: HashMap<u64, ChannelSnapshot>,
}

impl ConnectionRecord {
    fn new(host_id: String, address: String) -> Self {
        let now = now_ms();
        Self {
            host_id,
            address,
            owner_kind: "未关联".into(),
            owner_id: String::new(),
            created_at_ms: now,
            last_activity_at_ms: now,
            transport_state: TransportState::Connecting,
            ssh_state: SshState::Connecting,
            health_state: HealthState::Unknown,
            last_health_check_at_ms: None,
            received_bytes: 0,
            sent_bytes: 0,
            receive_bytes_per_second: 0,
            send_bytes_per_second: 0,
            rate_window_started: Instant::now(),
            rate_window_received: 0,
            rate_window_sent: 0,
            last_error: None,
            channels: HashMap::new(),
        }
    }

    fn update_rates(&mut self) {
        let elapsed = self.rate_window_started.elapsed();
        if elapsed < RATE_WINDOW {
            return;
        }
        let seconds = elapsed.as_secs_f64();
        self.receive_bytes_per_second = (self.rate_window_received as f64 / seconds) as u64;
        self.send_bytes_per_second = (self.rate_window_sent as f64 / seconds) as u64;
        self.rate_window_received = 0;
        self.rate_window_sent = 0;
        self.rate_window_started = Instant::now();
    }
}

#[derive(Default)]
pub struct TelemetryRegistry {
    next_id: AtomicU64,
    connections: Mutex<HashMap<u64, ConnectionRecord>>,
    events: Mutex<VecDeque<LifecycleEvent>>,
}

impl TelemetryRegistry {
    pub fn register_connection(&self, host_id: String, address: String) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        self.lock()
            .insert(id, ConnectionRecord::new(host_id, address));
        id
    }

    pub fn set_authenticated(&self, id: u64) {
        if let Some(record) = self.lock().get_mut(&id) {
            record.transport_state = TransportState::Active;
            record.ssh_state = SshState::Authenticated;
            record.health_state = HealthState::Healthy;
            record.last_error = None;
        }
    }

    pub fn set_owner(&self, id: u64, owner_kind: impl Into<String>, owner_id: impl Into<String>) {
        if let Some(record) = self.lock().get_mut(&id) {
            record.owner_kind = sanitize_owner(owner_kind.into());
            record.owner_id = sanitize_owner(owner_id.into());
        }
        self.record_event(id, LifecycleKind::Connected);
    }

    pub fn record_event(&self, id: u64, kind: LifecycleKind) {
        let connections = self.lock();
        let Some(record) = connections.get(&id) else {
            return;
        };
        // 本地已明确关闭后的 EOF/读写完成回调属于清理，不应污染最终状态和日志。
        if kind.is_error() && record.transport_state == TransportState::Closed {
            return;
        }
        let event = LifecycleEvent {
            connection_id: id,
            address: record.address.clone(),
            owner_kind: record.owner_kind.clone(),
            owner_id: record.owner_id.clone(),
            kind,
        };
        let mut events = self.events.lock().unwrap_or_else(|e| e.into_inner());
        if events.len() >= 1000 {
            events.pop_front();
        }
        events.push_back(event);
    }

    pub fn drain_events(&self) -> Vec<LifecycleEvent> {
        self.events
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain(..)
            .collect()
    }

    pub fn record_io(&self, id: u64, received: u64, sent: u64) {
        if let Some(record) = self.lock().get_mut(&id) {
            record.received_bytes = record.received_bytes.saturating_add(received);
            record.sent_bytes = record.sent_bytes.saturating_add(sent);
            // SSH disconnect 帧及 Socket 清理可能在关闭标记之后才完成底层 I/O。
            // 可以保留最终字节计数，但终态不可被晚到回调重新推进为 Active。
            let is_terminal = matches!(
                record.transport_state,
                TransportState::Closed | TransportState::Failed
            );
            record.rate_window_received = record.rate_window_received.saturating_add(received);
            record.rate_window_sent = record.rate_window_sent.saturating_add(sent);
            if !is_terminal && (received > 0 || sent > 0) {
                record.last_activity_at_ms = now_ms();
                record.transport_state = TransportState::Active;
            }
            record.update_rates();
        }
    }

    pub fn mark_idle(&self, id: u64) {
        if let Some(record) = self.lock().get_mut(&id) {
            if record.transport_state == TransportState::Active {
                record.transport_state = TransportState::Idle;
            }
        }
    }

    pub fn fail(&self, id: u64, error: String) {
        if let Some(record) = self.lock().get_mut(&id) {
            if record.transport_state == TransportState::Closed {
                return;
            }
            record.transport_state = TransportState::Failed;
            record.ssh_state = SshState::Failed;
            record.health_state = HealthState::Unavailable;
            record.last_error = Some(sanitize_error(error));
        }
    }

    pub fn close_connection(&self, id: u64) {
        if let Some(record) = self.lock().get_mut(&id) {
            if record.transport_state != TransportState::Failed {
                record.transport_state = TransportState::Closed;
                record.ssh_state = SshState::Closed;
                record.health_state = HealthState::Unknown;
            }
            for channel in record.channels.values_mut() {
                if channel.state == ChannelState::Open {
                    channel.state = ChannelState::Closed;
                }
            }
        }
    }

    /// 最后一个会话所有者释放后移除记录，避免监控注册表随重连无限增长。
    pub fn unregister_connection(&self, id: u64) -> bool {
        self.record_event(id, LifecycleKind::Released);
        self.lock().remove(&id).is_some()
    }

    pub fn set_health(&self, id: u64, state: HealthState, error: Option<String>) -> bool {
        let mut connections = self.lock();
        let Some(record) = connections.get_mut(&id) else {
            return false;
        };
        record.health_state = state;
        record.last_health_check_at_ms = Some(now_ms());
        record.last_error = error.map(sanitize_error);
        if state == HealthState::Unavailable {
            record.ssh_state = SshState::Failed;
        }
        true
    }

    pub fn open_channel(&self, connection_id: u64, kind: ChannelKind) -> u64 {
        let channel_id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let mut connections = self.lock();
        let Some(record) = connections.get_mut(&connection_id) else {
            return channel_id;
        };
        let now = now_ms();
        record.channels.insert(
            channel_id,
            ChannelSnapshot {
                id: channel_id,
                kind,
                state: ChannelState::Open,
                created_at_ms: now,
                last_activity_at_ms: now,
                received_bytes: 0,
                sent_bytes: 0,
            },
        );
        channel_id
    }

    pub fn update_channel(
        &self,
        connection_id: u64,
        channel_id: u64,
        received: u64,
        sent: u64,
        state: Option<ChannelState>,
    ) -> bool {
        let mut connections = self.lock();
        let Some(channel) = connections
            .get_mut(&connection_id)
            .and_then(|record| record.channels.get_mut(&channel_id))
        else {
            return false;
        };
        channel.received_bytes = channel.received_bytes.saturating_add(received);
        channel.sent_bytes = channel.sent_bytes.saturating_add(sent);
        if received > 0 || sent > 0 {
            channel.last_activity_at_ms = now_ms();
        }
        if let Some(state) = state {
            // 失败是终态，后台清理不能把写入失败误报成普通关闭。
            if channel.state != ChannelState::Failed || state != ChannelState::Closed {
                channel.state = state;
            }
        }
        true
    }

    pub fn contains(&self, id: u64) -> bool {
        self.lock().contains_key(&id)
    }

    pub fn recent_health(&self, id: u64, minimum_interval: Duration) -> Option<HealthState> {
        let connections = self.lock();
        let record = connections.get(&id)?;
        let checked_at = record.last_health_check_at_ms?;
        if now_ms().saturating_sub(checked_at) < minimum_interval.as_millis() as u64 {
            Some(record.health_state)
        } else {
            None
        }
    }

    pub fn snapshot(&self) -> Vec<ConnectionSnapshot> {
        let mut connections = self.lock();
        let mut result: Vec<_> = connections
            .iter_mut()
            .map(|(&id, record)| {
                record.update_rates();
                if record.transport_state == TransportState::Active
                    && now_ms().saturating_sub(record.last_activity_at_ms) >= IDLE_AFTER_MS
                {
                    record.transport_state = TransportState::Idle;
                }
                let mut channels: Vec<_> = record.channels.values().cloned().collect();
                channels.sort_by_key(|channel| channel.id);
                ConnectionSnapshot {
                    id,
                    host_id: record.host_id.clone(),
                    address: record.address.clone(),
                    owner_kind: record.owner_kind.clone(),
                    owner_id: record.owner_id.clone(),
                    created_at_ms: record.created_at_ms,
                    last_activity_at_ms: record.last_activity_at_ms,
                    transport_state: record.transport_state,
                    ssh_state: record.ssh_state,
                    health_state: record.health_state,
                    last_health_check_at_ms: record.last_health_check_at_ms,
                    received_bytes: record.received_bytes,
                    sent_bytes: record.sent_bytes,
                    receive_bytes_per_second: record.receive_bytes_per_second,
                    send_bytes_per_second: record.send_bytes_per_second,
                    last_error: record.last_error.clone(),
                    channels,
                }
            })
            .collect();
        result.sort_by_key(|record| record.id);
        result
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, ConnectionRecord>> {
        self.connections
            .lock()
            .expect("telemetry registry lock poisoned")
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn sanitize_error(error: String) -> String {
    error.chars().take(256).collect()
}

fn sanitize_owner(value: String) -> String {
    value.chars().take(128).collect()
}

static GLOBAL: OnceLock<Arc<TelemetryRegistry>> = OnceLock::new();

pub fn global_registry() -> &'static Arc<TelemetryRegistry> {
    GLOBAL.get_or_init(|| Arc::new(TelemetryRegistry::default()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_lifecycle_reason_has_fixed_description_and_severity() {
        use super::LifecycleKind::*;
        for kind in [
            Connected,
            ShellExit,
            ExplicitClose,
            SocketEof,
            ReadError,
            WriteError,
            KeepaliveFailed,
            TransportError,
            Released,
        ] {
            assert!(!kind.description().is_empty());
            assert_eq!(
                kind.is_error(),
                matches!(
                    kind,
                    SocketEof | ReadError | WriteError | KeepaliveFailed | TransportError
                )
            );
        }
    }

    #[test]
    fn cleanup_does_not_overwrite_failed_transport_state() {
        let registry = super::TelemetryRegistry::default();
        let id = registry.register_connection("fixture".into(), "example.test:22".into());
        registry.fail(id, "读取失败".into());
        registry.close_connection(id);
        assert_eq!(
            registry.snapshot()[0].transport_state,
            super::TransportState::Failed
        );
    }

    #[test]
    fn expected_eof_after_explicit_close_does_not_create_failure() {
        let registry = super::TelemetryRegistry::default();
        let id = registry.register_connection("fixture".into(), "example.test:22".into());
        registry.close_connection(id);
        registry.fail(id, "关闭后的 EOF".into());
        registry.record_event(id, super::LifecycleKind::SocketEof);
        assert_eq!(
            registry.snapshot()[0].transport_state,
            super::TransportState::Closed
        );
        assert!(registry.drain_events().is_empty());
    }

    #[test]
    fn closing_transport_cannot_be_reactivated_by_late_io_or_reported_as_error() {
        let registry = super::TelemetryRegistry::default();
        let id = registry.register_connection("fixture".into(), "example.test:22".into());
        registry.set_authenticated(id);
        registry.close_connection(id);

        // 真实连接在发送 SSH disconnect 帧时仍可能完成一次底层 write；
        // 这属于关闭清理，不能把 Closed 重新改成 Active。
        registry.record_io(id, 0, 24);
        registry.fail(id, "关闭后的 disconnect 回调".into());
        registry.record_event(id, super::LifecycleKind::TransportError);

        let snapshot = registry.snapshot().pop().unwrap();
        assert_eq!(snapshot.transport_state, super::TransportState::Closed);
        assert_eq!(snapshot.ssh_state, super::SshState::Closed);
        assert_eq!(snapshot.health_state, super::HealthState::Unknown);
        assert!(snapshot.last_error.is_none());
        assert!(registry.drain_events().is_empty());
    }

    #[test]
    fn lifecycle_events_survive_release_and_are_bounded_and_payload_free() {
        let registry = super::TelemetryRegistry::default();
        let id = registry.register_connection("h".into(), "example.test:22".into());
        registry.set_owner(id, "终端标签", "7");
        for _ in 0..1100 {
            registry.record_event(id, super::LifecycleKind::KeepaliveFailed);
        }
        registry.unregister_connection(id);
        let events = registry.drain_events();
        assert_eq!(events.len(), 1000);
        assert!(events
            .iter()
            .all(|event| event.connection_id == id && event.owner_id == "7"));
        assert_eq!(events.last().unwrap().kind, super::LifecycleKind::Released);
        assert!(registry.drain_events().is_empty());
    }
    use super::*;

    #[test]
    fn connection_snapshot_tracks_active_io_and_failure() {
        let registry = TelemetryRegistry::default();
        let id = registry.register_connection("h1".into(), "example.test:22".into());
        registry.set_authenticated(id);
        registry.set_owner(id, "终端", "tab-1");
        registry.record_io(id, 8, 3);
        let snapshot = registry.snapshot().pop().unwrap();
        assert_eq!(snapshot.transport_state, TransportState::Active);
        assert_eq!(snapshot.health_state, HealthState::Healthy);
        assert_eq!((snapshot.received_bytes, snapshot.sent_bytes), (8, 3));
        assert_eq!(
            (snapshot.owner_kind.as_str(), snapshot.owner_id.as_str()),
            ("终端", "tab-1")
        );
        registry.fail(id, "连接已关闭".into());
        assert_eq!(registry.snapshot()[0].ssh_state, SshState::Failed);
    }

    #[test]
    fn empty_registry_zero_io_and_unknown_ids_are_safe() {
        let registry = TelemetryRegistry::default();
        assert!(registry.snapshot().is_empty());
        registry.mark_idle(999);
        registry.fail(999, "ignored".into());
        registry.close_connection(999);
        let unattached_channel = registry.open_channel(999, ChannelKind::Exec);
        assert!(!registry.contains(999));
        let id = registry.register_connection("h".into(), "x:22".into());
        registry.record_io(id, 0, 0);
        assert_eq!(registry.snapshot()[0].sent_bytes, 0);
        assert!(!registry.set_health(999, HealthState::Healthy, None));
        assert!(!registry.update_channel(999, unattached_channel, 0, 0, None));
    }

    #[test]
    fn idle_is_not_failure_and_health_check_is_independent() {
        let registry = TelemetryRegistry::default();
        let id = registry.register_connection("h".into(), "x:22".into());
        registry.set_authenticated(id);
        registry.mark_idle(id);
        let snapshot = registry.snapshot().pop().unwrap();
        assert_eq!(snapshot.transport_state, TransportState::Idle);
        assert_eq!(snapshot.ssh_state, SshState::Authenticated);
        assert_eq!(snapshot.health_state, HealthState::Healthy);
    }

    #[test]
    fn channel_lifecycle_and_saturating_counts_are_recorded() {
        let registry = TelemetryRegistry::default();
        let connection_id = registry.register_connection("h".into(), "x:22".into());
        let channel_id = registry.open_channel(connection_id, ChannelKind::Shell);
        assert!(registry.update_channel(connection_id, channel_id, u64::MAX, 4, None));
        assert!(registry.update_channel(
            connection_id,
            channel_id,
            1,
            2,
            Some(ChannelState::Closed)
        ));
        let channel = &registry.snapshot()[0].channels[0];
        assert_eq!(channel.received_bytes, u64::MAX);
        assert_eq!(channel.sent_bytes, 6);
        assert_eq!(channel.state, ChannelState::Closed);
    }

    #[test]
    fn failed_channel_is_not_downgraded_by_later_cleanup() {
        let registry = TelemetryRegistry::default();
        let connection = registry.register_connection("h".into(), "x:22".into());
        let channel = registry.open_channel(connection, ChannelKind::Shell);
        assert!(registry.update_channel(connection, channel, 0, 0, Some(ChannelState::Failed)));
        assert!(registry.update_channel(connection, channel, 0, 0, Some(ChannelState::Closed)));
        assert_eq!(
            registry.snapshot()[0].channels[0].state,
            ChannelState::Failed
        );
    }

    #[test]
    fn released_connection_is_removed_from_snapshot() {
        let registry = TelemetryRegistry::default();
        let id = registry.register_connection("h".into(), "x:22".into());
        assert!(registry.unregister_connection(id));
        assert!(!registry.unregister_connection(id));
        assert!(registry.snapshot().is_empty());
    }

    #[test]
    fn concurrent_updates_do_not_lose_bytes() {
        let registry = Arc::new(TelemetryRegistry::default());
        let id = registry.register_connection("h".into(), "x:22".into());
        let threads: Vec<_> = (0..4)
            .map(|_| {
                let registry = Arc::clone(&registry);
                std::thread::spawn(move || {
                    for _ in 0..1_000 {
                        registry.record_io(id, 1, 2);
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let snapshot = registry.snapshot().pop().unwrap();
        assert_eq!(snapshot.received_bytes, 4_000);
        assert_eq!(snapshot.sent_bytes, 8_000);
    }

    #[test]
    fn error_summary_is_bounded() {
        let registry = TelemetryRegistry::default();
        let id = registry.register_connection("h".into(), "x:22".into());
        registry.fail(id, "x".repeat(300));
        assert_eq!(
            registry.snapshot()[0]
                .last_error
                .as_ref()
                .unwrap()
                .chars()
                .count(),
            256
        );
    }

    #[test]
    fn recent_health_throttles_repeated_checks() {
        let registry = TelemetryRegistry::default();
        let id = registry.register_connection("h".into(), "x:22".into());
        assert!(registry.recent_health(id, Duration::from_secs(1)).is_none());
        assert!(registry.set_health(id, HealthState::Healthy, None));
        assert_eq!(
            registry.recent_health(id, Duration::from_secs(1)),
            Some(HealthState::Healthy)
        );
        assert!(registry
            .recent_health(999, Duration::from_secs(1))
            .is_none());
    }
}
