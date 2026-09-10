use panda_core::task_summary::*;

fn task(id: &str, status: WorkStatus) -> WorkSnapshot {
    WorkSnapshot::new(id.into(), WorkKind::Upload, status, "/fixture/a".into())
}

#[test]
fn unfinished_includes_preparation_pause_and_decisions_but_not_terminal_records() {
    let states = [WorkStatus::Preparing, WorkStatus::Scanning, WorkStatus::Queued,
        WorkStatus::Running, WorkStatus::Paused, WorkStatus::WaitingForDecision,
        WorkStatus::Cancelling, WorkStatus::Completed, WorkStatus::Failed, WorkStatus::Cancelled];
    let tasks: Vec<_> = states.into_iter().enumerate().map(|(i, s)| task(&i.to_string(), s)).collect();
    assert_eq!(summarize_unfinished(&tasks).total, 7);
    assert_eq!(summarize_unfinished(&[]).total, 0);
}

#[test]
fn group_children_and_preparation_handoff_are_counted_once() {
    let mut registry = WorkRegistry::default();
    registry.begin(task("operation", WorkStatus::Preparing)).unwrap();
    let mut a = task("a", WorkStatus::Running);
    a.group_id = Some("group".into());
    let mut b = task("b", WorkStatus::Paused);
    b.group_id = a.group_id.clone();
    assert_eq!(summarize_unfinished(&[a.clone(), b.clone()]).total, 1);
    registry.attach("operation", "a").unwrap();
    registry.attach("operation", "b").unwrap();
    assert_eq!(summarize_unfinished(&registry.snapshots(&[a.clone(), b.clone()])).total, 1);
    registry.finish_preparation("operation", None).unwrap();
    assert_eq!(summarize_unfinished(&registry.snapshots(&[a, b])).total, 1);
}

#[test]
fn preparation_failure_is_visible_and_does_not_remain_active() {
    let mut registry = WorkRegistry::default();
    registry.begin(task("operation", WorkStatus::Preparing)).unwrap();
    assert_eq!(summarize_unfinished(&registry.snapshots(&[])).total, 1);
    registry.finish_preparation("operation", Some("扫描失败".into())).unwrap();
    let snapshots = registry.snapshots(&[]);
    assert_eq!(snapshots[0].status, WorkStatus::Failed);
    assert_eq!(snapshots[0].errors[0].message, "扫描失败");
    assert_eq!(summarize_unfinished(&snapshots).total, 0);
    registry.clear_finished();
    assert!(registry.snapshots(&[]).is_empty());
    assert!(registry.attach("missing", "a").is_err());
    assert!(registry.finish_preparation("missing", None).is_err());
}

#[test]
fn final_quit_gate_rechecks_and_cancel_reopens_registration() {
    let mut registry = WorkRegistry::default();
    registry.begin(task("new", WorkStatus::Preparing)).unwrap();
    assert!(!registry.confirm_quit(&[], false));
    assert!(registry.confirm_quit(&[], true));
    assert!(registry.begin(task("blocked", WorkStatus::Preparing)).is_err());
    registry.cancel_quit();
    registry.begin(task("accepted", WorkStatus::Preparing)).unwrap();
    assert_eq!(summarize_unfinished(&registry.snapshots(&[])).total, 2);
}

#[test]
fn empty_preparation_completes_and_local_delete_needs_no_host() {
    let mut registry = WorkRegistry::default();
    let local = WorkSnapshot::new("local".into(), WorkKind::LocalDelete, WorkStatus::Scanning, "/fixture".into());
    assert!(local.host_id.is_none());
    assert_eq!(local.total, None);
    assert_eq!(local.unit, ProgressUnit::Items);
    registry.begin(local).unwrap();
    registry.finish_preparation("local", None).unwrap();
    assert_eq!(registry.snapshots(&[])[0].status, WorkStatus::Completed);
    assert!(registry.confirm_quit(&[], false));
}

#[test]
fn operation_identity_does_not_collide_with_group_or_standalone_id() {
    let mut a = task("a", WorkStatus::Running);
    a.group_id = Some("same".into());
    let b = task("same", WorkStatus::Paused);
    let mut c = task("c", WorkStatus::Queued);
    c.operation_id = Some("same".into());
    assert_eq!(summarize_unfinished(&[a, b, c]).total, 3);
}
