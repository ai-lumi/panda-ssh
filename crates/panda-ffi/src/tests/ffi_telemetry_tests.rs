use super::*;
use crate::test_support::global_test_lock;

struct MonitorObserver {
    snapshots: std::sync::mpsc::Sender<Vec<ConnectionTelemetryRecord>>,
    dropped: std::sync::mpsc::Sender<()>,
}

impl ConnectionTelemetryObserver for MonitorObserver {
    fn on_snapshot(&self, snapshot: ConnectionTelemetrySnapshotRecord) {
        // 回调能重新查询核心，证明投递时没有持有核心状态锁。
        let _ = connection_telemetry_list();
        let newer = connection_telemetry_snapshot();
        assert!(newer.revision > snapshot.revision);
        let _ = self.snapshots.send(snapshot.records);
    }
}

impl Drop for MonitorObserver {
    fn drop(&mut self) {
        let _ = self.dropped.send(());
    }
}

#[test]
fn monitor_subscription_pushes_initial_and_changed_snapshot_and_cancels() {
    let _test_guard = global_test_lock();
    let (snapshots, received) = std::sync::mpsc::channel();
    let (dropped, released) = std::sync::mpsc::channel();
    let subscription =
        connection_telemetry_subscribe(Box::new(MonitorObserver { snapshots, dropped }));
    let deadline = std::time::Duration::from_secs(2);
    received.recv_timeout(deadline).unwrap();
    let registry = panda_core::telemetry::global_registry();
    let id = registry.register_connection("ffi-monitor".into(), "example.test:22".into());
    assert!(received
        .recv_timeout(deadline)
        .unwrap()
        .iter()
        .any(|record| record.id == id));
    registry.set_authenticated(id);
    let snapshot = received.recv_timeout(deadline).unwrap();
    let record = snapshot.iter().find(|record| record.id == id).unwrap();
    assert_eq!(record.ssh_state, SshConnectionStateEnum::Authenticated);
    subscription.cancel();
    subscription.cancel();
    released.recv_timeout(deadline).unwrap();
    registry.unregister_connection(id);
    assert!(received.recv_timeout(deadline).is_err());
}

#[test]
fn dropping_one_monitor_subscription_releases_observer_and_preserves_another() {
    let _test_guard = global_test_lock();
    let (snapshots, received) = std::sync::mpsc::channel();
    let (dropped, released) = std::sync::mpsc::channel();
    let first = connection_telemetry_subscribe(Box::new(MonitorObserver { snapshots, dropped }));
    let (snapshots, other_received) = std::sync::mpsc::channel();
    let (dropped, other_released) = std::sync::mpsc::channel();
    let second = connection_telemetry_subscribe(Box::new(MonitorObserver { snapshots, dropped }));
    let deadline = std::time::Duration::from_secs(2);
    received.recv_timeout(deadline).unwrap();
    other_received.recv_timeout(deadline).unwrap();
    drop(first);
    released.recv_timeout(deadline).unwrap();
    let registry = panda_core::telemetry::global_registry();
    let id = registry.register_connection("ffi-monitor".into(), "example.test:22".into());
    assert!(other_received
        .recv_timeout(deadline)
        .unwrap()
        .iter()
        .any(|record| record.id == id));
    registry.unregister_connection(id);
    assert!(other_received
        .recv_timeout(deadline)
        .unwrap()
        .iter()
        .all(|record| record.id != id));
    drop(second);
    other_released.recv_timeout(deadline).unwrap();
}

#[test]
fn lifecycle_record_has_only_safe_identifiers_and_fixed_reason() {
    let _test_guard = global_test_lock();
    let event = ConnectionLifecycleRecord::from(panda_core::telemetry::LifecycleEvent {
        connection_id: 42,
        address: "example.test:22".into(),
        owner_kind: "终端标签".into(),
        owner_id: "7".into(),
        kind: panda_core::telemetry::LifecycleKind::KeepaliveFailed,
    });
    assert!(event.is_error);
    assert_eq!(event.reason, "SSH keepalive 失败");
    assert_eq!(event.connection_id, 42);
}

#[test]
fn connection_snapshot_maps_all_structured_fields_without_sensitive_content() {
    let _test_guard = global_test_lock();
    use panda_core::telemetry::{
        ChannelKind, ChannelSnapshot, ChannelState, ConnectionSnapshot, HealthState, SshState,
        TransportState,
    };

    let record = ConnectionTelemetryRecord::from(ConnectionSnapshot {
        id: 7,
        host_id: "host-id".into(),
        address: "example.test:22".into(),
        owner_kind: "终端标签".into(),
        owner_id: "tab-7".into(),
        created_at_ms: 10,
        last_activity_at_ms: 20,
        transport_state: TransportState::Idle,
        ssh_state: SshState::Authenticated,
        health_state: HealthState::Healthy,
        last_health_check_at_ms: Some(19),
        received_bytes: u64::MAX,
        sent_bytes: u64::MAX - 1,
        receive_bytes_per_second: 123,
        send_bytes_per_second: 456,
        last_error: None,
        channels: vec![ChannelSnapshot {
            id: 8,
            kind: ChannelKind::Sftp,
            state: ChannelState::Open,
            created_at_ms: 11,
            last_activity_at_ms: 18,
            received_bytes: 99,
            sent_bytes: 100,
        }],
    });

    assert_eq!(record.transport_state, ConnectionStateEnum::Idle);
    assert_eq!(record.ssh_state, SshConnectionStateEnum::Authenticated);
    assert_eq!(record.health_state, HealthStateEnum::Healthy);
    assert_eq!(record.owner_kind, "终端标签");
    assert_eq!(record.owner_id, "tab-7");
    assert_eq!(record.received_bytes, u64::MAX);
    assert_eq!(record.channels.len(), 1);
    assert_eq!(record.channels[0].kind, ChannelKindEnum::Sftp);
    let exported = format!("{record:?}").to_lowercase();
    for forbidden in [
        "password",
        "credential",
        "command",
        "terminal_output",
        "file_content",
    ] {
        assert!(
            !exported.contains(forbidden),
            "导出记录包含敏感字段 {forbidden}"
        );
    }
}

#[test]
fn telemetry_list_can_be_empty_and_unknown_health_id_is_structured() {
    let _test_guard = global_test_lock();
    assert!(connection_telemetry_list().is_empty());
    assert!(matches!(
        connection_health_check(u64::MAX),
        Err(PandaError::UnknownConnection(id)) if id == u64::MAX
    ));
    assert!(connection_telemetry_list().is_empty());
}

#[test]
fn failure_classify_maps_every_error_code_to_its_category() {
    let _test_guard = global_test_lock();
    assert_eq!(
        connection_failure_classify("Timeout".into()).category,
        FailureCategoryEnum::Timeout
    );
    assert_eq!(
        connection_failure_classify("AuthFailed".into()).category,
        FailureCategoryEnum::AuthFailed
    );
    for code in [
        "MissingPassphrase",
        "CredentialProtectionKeyRequired",
        "CredentialUnlockFailed",
        "InvalidCredentialFile",
    ] {
        assert_eq!(
            connection_failure_classify(code.into()).category,
            FailureCategoryEnum::MissingCredential,
            "错误码 {code} 应分类为缺少凭据"
        );
    }
    // 其余错误码一律落到兜底分类，且文案非空
    for code in ["Cancelled", "ShellSessionClosed", "任意未知错误"] {
        let record = connection_failure_classify(code.into());
        assert_eq!(record.category, FailureCategoryEnum::Other);
        assert!(!record.title.is_empty());
    }
}

#[test]
fn map_failure_category_converts_core_variants_including_host_key_mismatch() {
    let _test_guard = global_test_lock();
    // HostKeyMismatch 经错误码字符串表不可达（变体携带参数），
    // 但映射必须保持完整，直接对映射函数验证。
    let core_to_ffi = [
        (
            panda_core::FailureCategory::Timeout,
            FailureCategoryEnum::Timeout,
        ),
        (
            panda_core::FailureCategory::AuthFailed,
            FailureCategoryEnum::AuthFailed,
        ),
        (
            panda_core::FailureCategory::MissingCredential,
            FailureCategoryEnum::MissingCredential,
        ),
        (
            panda_core::FailureCategory::HostKeyMismatch,
            FailureCategoryEnum::HostKeyMismatch,
        ),
        (
            panda_core::FailureCategory::Other,
            FailureCategoryEnum::Other,
        ),
    ];
    for (core, ffi) in core_to_ffi {
        assert_eq!(map_failure_category(core), ffi);
    }
}

#[test]
fn log_write_entries_and_clear_roundtrip_all_levels() {
    let _test_guard = global_test_lock();
    log_clear();
    log_write(
        LogLevelEnum::Debug,
        "ffi-log-test".into(),
        "调试消息".into(),
    );
    log_write(LogLevelEnum::Info, "ffi-log-test".into(), "信息消息".into());
    log_write(
        LogLevelEnum::Warning,
        "ffi-log-test".into(),
        "警告消息".into(),
    );
    log_write(
        LogLevelEnum::Error,
        "ffi-log-test".into(),
        "错误消息".into(),
    );

    // 全局 logger 可能被其他测试写入：只断言本测试写入的条目，按时间倒序
    let mine: Vec<LogEntryRecord> = log_entries(100)
        .into_iter()
        .filter(|e| e.module == "ffi-log-test")
        .collect();
    assert_eq!(mine.len(), 4);
    assert_eq!(mine[0].level, LogLevelEnum::Error);
    assert_eq!(mine[0].message, "错误消息");
    assert_eq!(mine[1].level, LogLevelEnum::Warning);
    assert_eq!(mine[2].level, LogLevelEnum::Info);
    assert_eq!(mine[3].level, LogLevelEnum::Debug);
    assert_eq!(mine[3].message, "调试消息");
    assert!(mine.iter().all(|e| e.id > 0));
    assert!(!mine[0].timestamp.is_empty());

    log_clear();
    assert!(log_entries(100)
        .into_iter()
        .all(|e| e.module != "ffi-log-test"));
}

// ---------------------------------------------------------------------------
// 13.3 三类测试：日志写入/查询、遥测与健康检查
// ---------------------------------------------------------------------------

/// 边界：limit=0 不崩溃且返回空。
#[test]
fn log_entries_with_zero_limit_returns_empty() {
    let _test_guard = global_test_lock();
    log_clear();
    log_write(LogLevelEnum::Info, "ffi-log-limit".into(), "消息".into());
    assert!(log_entries(0).is_empty());
    log_clear();
}

/// 边界：清空后再次读取返回空。
#[test]
fn log_entries_after_clear_returns_empty_for_module() {
    let _test_guard = global_test_lock();
    log_write(
        LogLevelEnum::Error,
        "ffi-log-clear-check".into(),
        "临时".into(),
    );
    log_clear();
    assert!(log_entries(1000)
        .iter()
        .all(|e| e.module != "ffi-log-clear-check"));
}

/// 正常：日志条目 ID 严格递增。
#[test]
fn log_entry_ids_are_monotonically_increasing() {
    let _test_guard = global_test_lock();
    log_clear();
    for i in 0..5 {
        log_write(
            LogLevelEnum::Info,
            "ffi-log-order".into(),
            format!("msg-{i}"),
        );
    }
    let all = log_entries(100);
    let mine: Vec<&LogEntryRecord> = all
        .iter()
        .filter(|e| e.module == "ffi-log-order")
        .collect();
    assert_eq!(mine.len(), 5);
    for window in mine.windows(2) {
        assert!(
            window[1].id < window[0].id,
            "倒序列表中后条目的 ID 应更小"
        );
    }
    log_clear();
}

/// 边界：无事件时 drain 返回空且不崩溃。
#[test]
fn lifecycle_drain_is_empty_when_no_events_are_recorded() {
    let _test_guard = global_test_lock();
    let first = connection_lifecycle_drain();
    let second = connection_lifecycle_drain();
    assert!(first.is_empty() || first.iter().all(|e| e.connection_id > 0));
    assert!(second.is_empty());
}

/// 边界：释放后的连接快照不包含任何敏感内容。
#[test]
fn released_connection_snapshot_remains_secret_free() {
    let _test_guard = global_test_lock();
    use panda_core::telemetry::{ConnectionSnapshot, HealthState, SshState, TransportState};

    let snapshot = ConnectionSnapshot {
        id: 99,
        host_id: "host-99".into(),
        address: "example.test:22".into(),
        owner_kind: "终端".into(),
        owner_id: "tab-99".into(),
        created_at_ms: 0,
        last_activity_at_ms: 0,
        transport_state: TransportState::Closed,
        ssh_state: SshState::Closed,
        health_state: HealthState::Unknown,
        last_health_check_at_ms: None,
        received_bytes: 0,
        sent_bytes: 0,
        receive_bytes_per_second: 0,
        send_bytes_per_second: 0,
        last_error: Some("AuthFailed".into()),
        channels: vec![],
    };
    let record = ConnectionTelemetryRecord::from(snapshot);
    let debug = format!("{record:?}").to_lowercase();
    for forbidden in [
        "password",
        "passphrase",
        "credential",
        "private_key",
        "secret",
    ] {
        assert!(
            !debug.contains(forbidden),
            "释放后快照包含敏感字段 {forbidden}"
        );
    }
    assert_eq!(record.transport_state, ConnectionStateEnum::Closed);
    assert_eq!(record.ssh_state, SshConnectionStateEnum::Closed);
}

/// 意外：对不存在的连接执行健康检查返回结构化错误且不产生副作用。
#[test]
fn health_check_on_unknown_connection_returns_structured_error() {
    let _test_guard = global_test_lock();
    let before = connection_telemetry_list().len();
    assert!(matches!(
        connection_health_check(0),
        Err(PandaError::UnknownConnection(0))
    ));
    assert!(matches!(
        connection_health_check(u64::MAX),
        Err(PandaError::UnknownConnection(id)) if id == u64::MAX
    ));
    assert_eq!(connection_telemetry_list().len(), before);
}
