use super::*;
use std::future::Future;
use std::task::{Context, Poll, Waker};

fn ready(subscription: &mut TelemetrySubscription) -> Option<Vec<ConnectionSnapshot>> {
    let mut next = std::pin::pin!(subscription.next_snapshot());
    match next.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(snapshot) => Some(snapshot.records),
        Poll::Pending => None,
    }
}

#[tokio::test(start_paused = true)]
async fn empty_subscription_waits_without_deadlines_and_wakes_for_connection() {
    let registry = Arc::new(TelemetryRegistry::default());
    let mut subscription = registry.subscribe();
    assert_eq!(ready(&mut subscription), Some(vec![]));
    assert!(subscription.deadline.is_none());
    tokio::time::advance(Duration::from_secs(60)).await;
    assert!(ready(&mut subscription).is_none());
    let id = registry.register_connection("h".into(), "x:22".into());
    assert_eq!(ready(&mut subscription).unwrap()[0].id, id);
    assert!(subscription.deadline.is_none());
}

#[tokio::test(start_paused = true)]
async fn every_visible_mutation_reaches_independent_subscribers() {
    let registry = Arc::new(TelemetryRegistry::default());
    let mut first = registry.subscribe();
    let mut second = registry.subscribe();
    // 注册观察者后、读取初始快照前的变化不能丢失。
    let id = registry.register_connection("h".into(), "x:22".into());
    assert_eq!(ready(&mut first), ready(&mut second));
    macro_rules! updated {
        () => {{
            let value = ready(&mut first).expect("每次可展示变化都必须唤醒订阅");
            assert_eq!(Some(value.clone()), ready(&mut second));
            value
        }};
    }
    registry.set_authenticated(id);
    assert_eq!(updated!()[0].ssh_state, SshState::Authenticated);
    registry.set_owner(id, "终端", "tab-1");
    assert_eq!(updated!()[0].owner_id, "tab-1");
    let channel = registry.open_channel(id, ChannelKind::Sftp);
    assert_eq!(updated!()[0].channels[0].id, channel);
    registry.update_channel(id, channel, 12, 4, None);
    assert_eq!(updated!()[0].channels[0].received_bytes, 12);
    registry.record_io(id, 20, 8);
    assert_eq!(updated!()[0].received_bytes, 20);
    registry.update_channel(id, channel, 0, 0, Some(ChannelState::Closed));
    assert_eq!(updated!()[0].channels[0].state, ChannelState::Closed);
    registry.set_health(id, HealthState::Unavailable, Some("失败".into()));
    assert_eq!(updated!()[0].health_state, HealthState::Unavailable);
    registry.fail(id, "读取失败".into());
    assert_eq!(updated!()[0].transport_state, TransportState::Failed);
    registry.unregister_connection(id);
    assert!(updated!().is_empty());
    assert!(first.deadline.is_none());
    drop(first);
    registry.register_connection("h2".into(), "y:22".into());
    assert_eq!(ready(&mut second).unwrap().len(), 1);
}

#[tokio::test(start_paused = true)]
async fn duplicates_invalid_ids_and_log_events_do_not_publish_snapshots() {
    let registry = Arc::new(TelemetryRegistry::default());
    let id = registry.register_connection("h".into(), "x:22".into());
    registry.set_authenticated(id);
    registry.mark_idle(id);
    let mut subscription = registry.subscribe();
    ready(&mut subscription).unwrap();
    registry.mark_idle(id);
    registry.record_io(id, 0, 0);
    registry.mark_idle(999);
    registry.fail(999, "无效".into());
    registry.record_event(id, LifecycleKind::Connected);
    registry.set_owner(999, "终端", "不存在");
    registry.open_channel(999, ChannelKind::Exec);
    registry.close_connection(999);
    registry.update_channel(id, 999, 0, 0, None);
    registry.set_health(999, HealthState::Healthy, None);
    assert!(!registry.unregister_connection(999));
    assert!(ready(&mut subscription).is_none());
    assert!(subscription.deadline.is_none());
    registry.close_connection(id);
    assert_eq!(
        ready(&mut subscription).unwrap()[0].ssh_state,
        SshState::Closed
    );
    registry.mark_explicit_close(id);
    registry.fail(id, "清理".into());
    registry.close_connection(id);
    assert!(ready(&mut subscription).is_none());
}

#[tokio::test(start_paused = true)]
async fn burst_updates_coalesce_without_losing_counts_or_terminal_state() {
    let registry = Arc::new(TelemetryRegistry::default());
    let mut subscription = registry.subscribe();
    assert!(ready(&mut subscription).unwrap().is_empty());
    let id = registry.register_connection("h".into(), "x:22".into());
    for _ in 0..1000 {
        registry.record_io(id, 1, 2);
    }
    registry.fail(id, "失败".into());
    registry.close_connection(id);
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(
        (snapshot[0].received_bytes, snapshot[0].sent_bytes),
        (1000, 2000)
    );
    assert_eq!(snapshot[0].transport_state, TransportState::Failed);
    assert!(ready(&mut subscription).is_none());
}

#[tokio::test(start_paused = true)]
async fn one_shot_deadlines_settle_rates_and_idle_then_stop() {
    let registry = Arc::new(TelemetryRegistry::default());
    let id = registry.register_connection("h".into(), "x:22".into());
    registry.set_authenticated(id);
    let mut subscription = registry.subscribe();
    ready(&mut subscription).unwrap();
    registry.record_io(id, 100, 50);
    ready(&mut subscription).unwrap();
    tokio::time::advance(RATE_WINDOW).await;
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(
        (
            snapshot[0].receive_bytes_per_second,
            snapshot[0].send_bytes_per_second
        ),
        (400, 200)
    );
    tokio::time::advance(RATE_WINDOW).await;
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(
        (
            snapshot[0].receive_bytes_per_second,
            snapshot[0].send_bytes_per_second
        ),
        (0, 0)
    );
    tokio::time::advance(Duration::from_millis(4499)).await;
    assert!(ready(&mut subscription).is_none());
    tokio::time::advance(Duration::from_millis(1)).await;
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(snapshot[0].transport_state, TransportState::Idle);
    assert_eq!(snapshot[0].health_state, HealthState::Healthy);
    assert!(subscription.deadline.is_none());
    registry.record_io(id, 1, 0);
    assert_eq!(
        ready(&mut subscription).unwrap()[0].transport_state,
        TransportState::Active
    );
    assert!(subscription.deadline.is_some());
}

#[tokio::test(start_paused = true)]
async fn new_activity_reschedules_idle_and_manual_snapshot_does_not_consume_event() {
    let registry = Arc::new(TelemetryRegistry::default());
    let id = registry.register_connection("h".into(), "x:22".into());
    registry.set_authenticated(id);
    let mut subscription = registry.subscribe();
    ready(&mut subscription).unwrap();
    tokio::time::advance(Duration::from_secs(4)).await;
    registry.record_io(id, 100, 0);
    let expected = registry.snapshot();
    assert_eq!(ready(&mut subscription), Some(expected));
    tokio::time::advance(Duration::from_secs(1)).await;
    assert_eq!(
        ready(&mut subscription).unwrap()[0].transport_state,
        TransportState::Active
    );
    tokio::time::advance(Duration::from_secs(4)).await;
    assert_eq!(
        ready(&mut subscription).unwrap()[0].transport_state,
        TransportState::Idle
    );
    assert!(subscription.deadline.is_none());
}

#[tokio::test(start_paused = true)]
async fn snapshot_order_is_shared_by_manual_reads_and_subscriptions() {
    let registry = Arc::new(TelemetryRegistry::default());
    let mut subscription = registry.subscribe();
    let first = subscription.next_snapshot().await;
    let id = registry.register_connection("h".into(), "x:22".into());
    let manual = registry.versioned_snapshot();
    let changed = subscription.next_snapshot().await;
    assert!(first.revision < manual.revision);
    assert!(manual.revision < changed.revision);
    assert_eq!(changed.records[0].id, id);
}

#[tokio::test(start_paused = true)]
async fn first_io_after_long_idle_starts_a_fresh_rate_window() {
    let registry = Arc::new(TelemetryRegistry::default());
    let id = registry.register_connection("h".into(), "x:22".into());
    registry.set_authenticated(id);
    registry.mark_idle(id);
    let mut subscription = registry.subscribe();
    ready(&mut subscription).unwrap();
    tokio::time::advance(Duration::from_secs(60)).await;
    assert!(ready(&mut subscription).is_none());
    registry.record_io(id, 100, 50);
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(snapshot[0].receive_bytes_per_second, 0, "新窗口尚未结算");
    tokio::time::advance(RATE_WINDOW).await;
    let snapshot = ready(&mut subscription).unwrap();
    assert_eq!(
        (
            snapshot[0].receive_bytes_per_second,
            snapshot[0].send_bytes_per_second
        ),
        (400, 200)
    );
}
