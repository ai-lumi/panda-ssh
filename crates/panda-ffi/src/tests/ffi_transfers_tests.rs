use super::*;
use crate::test_support::global_test_lock;
use std::time::Duration;

fn wait_for_ffi_status(id: &str, expected: TransferStatusEnum) -> TransferStatusRecord {
    for _ in 0..300 {
        if let Ok(snap) = transfer_status(id.to_string()) {
            if snap.status == expected {
                return snap;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("task {id} did not reach {expected:?} in time");
}

fn start_refused_upload() -> String {
    start_transfer(
        TransferDirectionEnum::Upload,
        "refused-host".into(),
        "/tmp/test".into(),
        "/remote/test".into(),
        100,
        Some("pw".into()),
        None,
        None,
        None,
    )
    .unwrap()
}

// ---------------------------------------------------------------------------
// 变更计数器
// ---------------------------------------------------------------------------

#[test]
fn change_counter_does_not_increment_on_read() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let v1 = transfer_change_counter();
    let v2 = transfer_change_counter();
    assert_eq!(v1, v2);
}

#[test]
fn notify_transfer_changed_increments_counter() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let before = transfer_change_counter();
    notify_transfer_changed();
    let after = transfer_change_counter();
    assert_eq!(after, before + 1);
}

#[test]
fn change_counter_syncs_via_callback() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let before = transfer_change_counter();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    let after = transfer_change_counter();
    assert!(
        after > before,
        "FFI 计数器应通过核心回调同步递增: before={before}, after={after}"
    );
}

#[test]
fn change_counter_increments_on_multiple_transitions() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let c0 = transfer_change_counter();
    let retried = transfer_retry(id.clone()).unwrap();
    assert_eq!(retried, id);
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    let c1 = transfer_change_counter();
    assert!(
        c1 > c0,
        "重试应触发状态转换并递增计数器: c0={c0}, c1={c1}"
    );
}

// ---------------------------------------------------------------------------
// 类型转换
// ---------------------------------------------------------------------------

#[test]
fn direction_conversion_round_trip() {
    assert_eq!(
        from_core_direction(to_core_direction(TransferDirectionEnum::Upload)),
        TransferDirectionEnum::Upload
    );
    assert_eq!(
        from_core_direction(to_core_direction(TransferDirectionEnum::Download)),
        TransferDirectionEnum::Download
    );
}

#[test]
fn status_conversion_covers_all_variants() {
    use panda_core::transfer::TransferStatus;
    let cases = [
        (TransferStatus::Queued, TransferStatusEnum::Queued),
        (TransferStatus::Running, TransferStatusEnum::Running),
        (TransferStatus::Paused, TransferStatusEnum::Paused),
        (TransferStatus::Completed, TransferStatusEnum::Completed),
        (TransferStatus::Failed, TransferStatusEnum::Failed),
        (TransferStatus::Cancelled, TransferStatusEnum::Cancelled),
        (TransferStatus::Skipped, TransferStatusEnum::Skipped),
    ];
    for (core, ffi) in cases {
        assert_eq!(from_core_status(core), ffi);
    }
}

#[test]
fn snapshot_to_record_converts_all_fields() {
    use panda_core::transfer::{TransferDirection, TransferSnapshot, TransferStatus};
    let snap = TransferSnapshot {
        id: "abc".into(),
        direction: TransferDirection::Upload,
        host_id: "h1".into(),
        local_path: "/local".into(),
        remote_path: "/remote".into(),
        size: 100,
        transferred: 50,
        status: TransferStatus::Running,
        error: Some("err".into()),
        version: 3,
        speed: 1.5,
        total_speed: 2.5,
        eta_seconds: Some(10.0),
        group_id: Some("g1".into()),
        group_name: Some("组".into()),
        conflict: None,
    };
    let rec = snapshot_to_record(snap);
    assert_eq!(rec.id, "abc");
    assert_eq!(rec.direction, TransferDirectionEnum::Upload);
    assert_eq!(rec.status, TransferStatusEnum::Running);
    assert_eq!(rec.error, Some("err".into()));
    assert_eq!(rec.group_id, Some("g1".into()));
    assert_eq!(rec.group_name, Some("组".into()));
    assert_eq!(rec.transferred, 50);
    assert_eq!(rec.size, 100);
}

#[test]
fn group_to_record_converts_all_fields() {
    use panda_core::transfer::{TransferDirection, TransferGroupSnapshot, TransferStatus};
    let g = TransferGroupSnapshot {
        group_id: "g1".into(),
        group_name: "组一".into(),
        direction: TransferDirection::Download,
        total_count: 3,
        completed_count: 1,
        total_bytes: 300,
        transferred_bytes: 100,
        status: TransferStatus::Running,
    };
    let rec = group_to_record(g);
    assert_eq!(rec.group_id, "g1");
    assert_eq!(rec.group_name, "组一");
    assert_eq!(rec.direction, TransferDirectionEnum::Download);
    assert_eq!(rec.status, TransferStatusEnum::Running);
    assert_eq!(rec.total_count, 3);
    assert_eq!(rec.completed_count, 1);
    assert_eq!(rec.total_bytes, 300);
    assert_eq!(rec.transferred_bytes, 100);
}

// ---------------------------------------------------------------------------
// total_size
// ---------------------------------------------------------------------------

#[test]
fn total_size_zero_for_missing_file() {
    assert_eq!(total_size(std::path::Path::new("/nonexistent/path")), 0);
}

#[test]
fn total_size_returns_file_length() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("data.bin");
    std::fs::write(&path, b"hello").unwrap();
    assert_eq!(total_size(path.as_path()), 5);
}

// ---------------------------------------------------------------------------
// 错误映射
// ---------------------------------------------------------------------------

#[test]
fn unknown_task_returns_structured_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = uuid::Uuid::new_v4().to_string();
    assert!(matches!(
        transfer_status(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_cancel(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_pause(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_resume(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_retry(id),
        Err(PandaError::UnknownTransferTask(_))
    ));
}

#[test]
fn invalid_task_id_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    assert!(transfer_status("not-a-uuid".into()).is_err());
    assert!(transfer_retry("not-a-uuid".into()).is_err());
}

#[test]
fn pause_terminal_task_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    let err = transfer_pause(id).unwrap_err();
    assert!(err.to_string().contains("already terminal"));
}

// ---------------------------------------------------------------------------
// 正常流程（通过真实 FfiExecutor + 拒绝连接主机）
// ---------------------------------------------------------------------------

#[test]
fn start_transfer_returns_id_and_reaches_failed_for_refused_host() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    let snap = wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    assert_eq!(snap.direction, TransferDirectionEnum::Upload);
    assert_eq!(snap.host_id, "refused-host");
    assert_eq!(snap.size, 100);
    assert!(snap.error.is_some(), "连接拒绝应设置错误信息");
}

#[test]
fn transfer_list_returns_all_tasks() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let mut ids = Vec::new();
    for i in 0..3 {
        let id = start_transfer(
            TransferDirectionEnum::Upload,
            "refused-host".into(),
            format!("/tmp/f{i}"),
            format!("/remote/f{i}"),
            100,
            Some("pw".into()),
            None,
            None,
            None,
        )
        .unwrap();
        ids.push(id);
    }
    let list = transfer_list().unwrap();
    assert_eq!(list.len(), 3);
    for id in &ids {
        wait_for_ffi_status(id, TransferStatusEnum::Failed);
    }
}

#[test]
fn cancel_before_execution_sets_cancelled() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let id2 = start_refused_upload();
    transfer_cancel(id2.clone()).unwrap();
    let snap = wait_for_ffi_status(&id2, TransferStatusEnum::Cancelled);
    assert!(snap.error.is_none() || snap.status == TransferStatusEnum::Cancelled);
}

#[test]
fn retry_resets_state_and_runs_again() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let retried = transfer_retry(id.clone()).unwrap();
    assert_eq!(retried, id);
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    let snap = transfer_status(id).unwrap();
    assert!(snap.error.is_some(), "重试后应再次失败并携带错误");
}

#[test]
fn retry_non_retryable_state_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    assert!(matches!(
        transfer_retry(uuid::Uuid::new_v4().to_string()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(transfer_retry("not-a-uuid".into()).is_err());

    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let retried = transfer_retry(id.clone()).unwrap();
    assert_eq!(retried, id);
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
}

#[test]
fn cancel_completed_or_failed_task_is_noop_for_status() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let _before = transfer_change_counter();
    transfer_cancel(id.clone()).unwrap();
    let snap = transfer_status(id).unwrap();
    assert_eq!(snap.status, TransferStatusEnum::Failed);
}

#[test]
fn resume_on_non_paused_task_is_noop() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_refused_upload();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    let _before = transfer_change_counter();
    transfer_resume(id.clone()).unwrap();
    let snap = transfer_status(id).unwrap();
    assert_eq!(snap.status, TransferStatusEnum::Failed);
}

// ---------------------------------------------------------------------------
// 组聚合
// ---------------------------------------------------------------------------

#[test]
fn transfer_groups_aggregates_grouped_tasks() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    for i in 0..2 {
        start_transfer(
            TransferDirectionEnum::Upload,
            "refused-host".into(),
            format!("/tmp/gf{i}"),
            format!("/remote/gf{i}"),
            100,
            Some("pw".into()),
            None,
            Some("g1".into()),
            Some("组一".into()),
        )
        .unwrap();
    }
    let _ungrouped = start_transfer(
        TransferDirectionEnum::Upload,
        "refused-host".into(),
        "/tmp/ungrouped".into(),
        "/remote/ungrouped".into(),
        50,
        Some("pw".into()),
        None,
        None,
        None,
    )
    .unwrap();

    let mut all_terminal = false;
    for _ in 0..300 {
        let list = transfer_list().unwrap();
        if list
            .iter()
            .all(|t| t.status == TransferStatusEnum::Failed)
        {
            all_terminal = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(all_terminal, "所有任务应到达终态");

    let groups = transfer_groups().unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].group_id, "g1");
    assert_eq!(groups[0].group_name, "组一");
    assert_eq!(groups[0].total_count, 2);
    assert_eq!(groups[0].completed_count, 2);
    assert_eq!(groups[0].total_bytes, 200);
}

// ---------------------------------------------------------------------------
// SSH 连接拒绝（真实 FfiExecutor）
// ---------------------------------------------------------------------------

#[test]
fn real_executor_marks_failed_when_connection_refused() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    let id = start_transfer(
        TransferDirectionEnum::Download,
        "refused-host".into(),
        "/tmp/test".into(),
        "/remote/test".into(),
        100,
        Some("pw".into()),
        None,
        None,
        None,
    )
    .unwrap();

    let snap = wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    assert!(snap.error.is_some(), "连接拒绝应设置错误信息");
    assert_eq!(snap.direction, TransferDirectionEnum::Download);
}

// ---------------------------------------------------------------------------
// 组控制（FFI 委托核心）
// ---------------------------------------------------------------------------

#[test]
fn group_cancel_unknown_group_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    assert!(transfer_group_cancel("nonexistent".into()).is_err());
}

#[test]
fn group_pause_unknown_group_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    assert!(transfer_group_pause("nonexistent".into()).is_err());
}

#[test]
fn group_resume_unknown_group_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    assert!(transfer_group_resume("nonexistent".into()).is_err());
}

#[test]
fn group_retry_unknown_group_returns_error() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    assert!(transfer_group_retry("nonexistent".into()).is_err());
}

#[test]
fn group_retry_retries_failed_tasks_via_ffi() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    for i in 0..2 {
        start_transfer(
            TransferDirectionEnum::Upload,
            "refused-host".into(),
            format!("/tmp/gr{i}"),
            format!("/remote/gr{i}"),
            100,
            Some("pw".into()),
            None,
            Some("g1".into()),
            Some("重试组".into()),
        )
        .unwrap();
    }

    let mut all_failed = false;
    for _ in 0..300 {
        let list = transfer_list().unwrap();
        if list.iter().all(|t| t.status == TransferStatusEnum::Failed) {
            all_failed = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(all_failed, "所有任务应先到达 Failed");

    transfer_group_retry("g1".into()).unwrap();

    let mut all_failed_again = false;
    for _ in 0..300 {
        let list = transfer_list().unwrap();
        if list.iter().all(|t| t.status == TransferStatusEnum::Failed) {
            all_failed_again = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(all_failed_again, "重试后任务应再次到达 Failed");
}

#[test]
fn group_cancel_on_terminal_tasks_is_noop() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        "refused-host".into(),
        "/tmp/gc".into(),
        "/remote/gc".into(),
        100,
        Some("pw".into()),
        None,
        Some("g1".into()),
        Some("取消组".into()),
    )
    .unwrap();

    wait_for_ffi_status(&id, TransferStatusEnum::Failed);

    transfer_group_cancel("g1".into()).unwrap();
    let snap = transfer_status(id).unwrap();
    assert_eq!(snap.status, TransferStatusEnum::Failed);
}

// ---------------------------------------------------------------------------
// SFTP 编排
// ---------------------------------------------------------------------------

fn reset_both_services() {
    reset_transfer_service_for_test();
    super::batch_transfer::reset_batch_service_for_test();
}

fn file_record(source: &str, dest: &str, size: u64) -> TaskItemRecord {
    TaskItemRecord {
        source: source.into(),
        destination: dest.into(),
        size,
        name: source.rsplit('/').next().unwrap_or(source).into(),
        is_dir: false,
    }
}

fn dir_record(source: &str, dest: &str) -> TaskItemRecord {
    TaskItemRecord {
        source: source.into(),
        destination: dest.into(),
        size: 0,
        name: source.rsplit('/').next().unwrap_or(source).into(),
        is_dir: true,
    }
}

#[test]
fn orchestration_single_file_upload_returns_one_transfer() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/tmp/file.txt".into()],
        vec![file_record("/tmp/file.txt", "/remote/file.txt", 100)],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 1);
    assert!(result.batch_ids.is_empty());
}

#[test]
fn orchestration_directory_upload_returns_per_file_transfers() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/tmp/dirA".into()],
        vec![
            dir_record("/tmp/dirA", "/remote/dirA"),
            file_record("/tmp/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
        ],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 1, "目录上传产生逐文件传输");
    assert!(result.batch_ids.is_empty(), "不再产生整体批量任务");
    let snap = transfer_status(result.transfer_ids[0].clone()).unwrap();
    assert!(snap.group_id.is_some(), "目录内文件应关联组 ID");
    assert_eq!(snap.direction, TransferDirectionEnum::Upload);
}

#[test]
fn orchestration_mixed_upload_returns_all_transfers() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/tmp/dirA".into(), "/tmp/readme.md".into()],
        vec![
            dir_record("/tmp/dirA", "/remote/dirA"),
            file_record("/tmp/dirA/f1.txt", "/remote/dirA/f1.txt", 100),
            file_record("/tmp/readme.md", "/remote/readme.md", 50),
        ],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 2, "目录文件与独立文件均为逐文件传输");
    assert!(result.batch_ids.is_empty(), "不再产生整体批量任务");
    let grouped = transfer_status(result.transfer_ids[0].clone()).unwrap();
    let standalone = transfer_status(result.transfer_ids[1].clone()).unwrap();
    assert!(grouped.group_id.is_some(), "目录内文件应关联组 ID");
    assert!(standalone.group_id.is_none(), "独立文件不应有组 ID");
}

#[test]
fn orchestration_download_directory_returns_individual_transfers() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/remote/dirA".into()],
        vec![
            dir_record("/remote/dirA", "/tmp/dirA"),
            file_record("/remote/dirA/f1.txt", "/tmp/dirA/f1.txt", 100),
            file_record("/remote/dirA/f2.txt", "/tmp/dirA/f2.txt", 200),
        ],
        TransferDirectionEnum::Download,
        "test-host".into(),
        "/tmp".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 2);
    assert!(result.batch_ids.is_empty());
    for id in &result.transfer_ids {
        let snap = transfer_status(id.clone()).unwrap();
        assert_eq!(snap.group_id.as_ref().unwrap(), snap.group_id.as_ref().unwrap());
    }
}

#[test]
fn orchestration_empty_items_returns_empty_result() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec![],
        vec![],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        None,
        None,
    )
    .unwrap();
    assert!(result.transfer_ids.is_empty());
    assert!(result.batch_ids.is_empty());
}

#[test]
fn orchestration_unknown_host_returns_error() {
    let _g = global_test_lock();
    reset_both_services();
    let err = orchestrate_sftp_transfers(
        vec!["/tmp/file.txt".into()],
        vec![file_record("/tmp/file.txt", "/remote/file.txt", 100)],
        TransferDirectionEnum::Upload,
        "nonexistent-host".into(),
        "/remote".into(),
        None,
        None,
    )
    .unwrap_err();
    match err {
        PandaError::UnknownHost(ref h) if h == "nonexistent-host" => {}
        _ => panic!("expected PandaError::UnknownHost, got {err:?}"),
    }
}

// ---------------------------------------------------------------------------
// 6.1 契约补充：凭据隔离、空选择区分、组关联、路径一致性
// ---------------------------------------------------------------------------

#[test]
fn snapshot_record_does_not_carry_credentials() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();
    let id = start_transfer(
        TransferDirectionEnum::Upload,
        "refused-host".into(),
        "/tmp/secret".into(),
        "/remote/secret".into(),
        100,
        Some("super-secret-password".into()),
        Some("super-secret-passphrase".into()),
        None,
        None,
    )
    .unwrap();
    wait_for_ffi_status(&id, TransferStatusEnum::Failed);
    let snap = transfer_status(id).unwrap();
    assert_eq!(snap.local_path, "/tmp/secret");
    assert_eq!(snap.remote_path, "/remote/secret");
    assert_eq!(snap.host_id, "refused-host");
    let snap_debug = format!("{snap:?}");
    assert!(
        !snap_debug.contains("super-secret-password"),
        "快照不应包含密码明文"
    );
    assert!(
        !snap_debug.contains("super-secret-passphrase"),
        "快照不应包含口令明文"
    );
}

#[test]
fn group_snapshot_does_not_carry_credentials() {
    use panda_core::transfer::{TransferDirection, TransferGroupSnapshot, TransferStatus};
    let g = TransferGroupSnapshot {
        group_id: "g1".into(),
        group_name: "秘组".into(),
        direction: TransferDirection::Upload,
        total_count: 1,
        completed_count: 0,
        total_bytes: 100,
        transferred_bytes: 0,
        status: TransferStatus::Running,
    };
    let rec = group_to_record(g);
    let debug = format!("{rec:?}");
    assert!(!debug.contains("password"));
    assert!(!debug.contains("passphrase"));
}

#[test]
fn orchestration_empty_selection_returns_empty_without_host_lookup() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec![],
        vec![],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        None,
        None,
    )
    .unwrap();
    assert!(result.transfer_ids.is_empty());
    assert!(result.batch_ids.is_empty());
}

#[test]
fn orchestration_empty_directory_produces_no_tasks() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/tmp/emptydir".into()],
        vec![dir_record("/tmp/emptydir", "/remote/emptydir")],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        None,
        None,
    )
    .unwrap();
    assert!(result.transfer_ids.is_empty(), "空目录无文件传输");
    assert!(result.batch_ids.is_empty(), "空目录不再产生批量任务");
}

#[test]
fn orchestration_download_directory_files_share_group_id() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/remote/dirB".into()],
        vec![
            dir_record("/remote/dirB", "/tmp/dirB"),
            file_record("/remote/dirB/a.txt", "/tmp/dirB/a.txt", 100),
            file_record("/remote/dirB/b.txt", "/tmp/dirB/b.txt", 200),
        ],
        TransferDirectionEnum::Download,
        "test-host".into(),
        "/tmp".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 2);
    let snap_a = transfer_status(result.transfer_ids[0].clone()).unwrap();
    let snap_b = transfer_status(result.transfer_ids[1].clone()).unwrap();
    assert!(snap_a.group_id.is_some(), "目录下载文件应关联组 ID");
    assert_eq!(snap_a.group_id, snap_b.group_id, "同目录文件应共享组 ID");
    assert_eq!(snap_a.group_name, snap_b.group_name);
    assert_eq!(snap_a.direction, TransferDirectionEnum::Download);
}

#[test]
fn orchestration_upload_snapshot_paths_match_plan() {
    let _g = global_test_lock();
    reset_both_services();
    let result = orchestrate_sftp_transfers(
        vec!["/tmp/file.txt".into()],
        vec![file_record("/tmp/file.txt", "/remote/file.txt", 42)],
        TransferDirectionEnum::Upload,
        "test-host".into(),
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    assert_eq!(result.transfer_ids.len(), 1);
    let snap = transfer_status(result.transfer_ids[0].clone()).unwrap();
    assert_eq!(snap.local_path, "/tmp/file.txt");
    assert_eq!(snap.remote_path, "/remote/file.txt");
    assert_eq!(snap.size, 42);
    assert_eq!(snap.host_id, "test-host");
    assert!(snap.group_id.is_none(), "独立文件不应有组 ID");
}

#[test]
fn group_retry_preserves_task_ids_via_ffi() {
    let _g = global_test_lock();
    reset_transfer_service_for_test();

    let mut ids = Vec::new();
    for i in 0..2 {
        let id = start_transfer(
            TransferDirectionEnum::Upload,
            "refused-host".into(),
            format!("/tmp/rid{i}"),
            format!("/remote/rid{i}"),
            100,
            Some("pw".into()),
            None,
            Some("g-retry".into()),
            Some("重试组".into()),
        )
        .unwrap();
        ids.push(id);
    }

    for id in &ids {
        wait_for_ffi_status(id, TransferStatusEnum::Failed);
    }

    transfer_group_retry("g-retry".into()).unwrap();

    for id in &ids {
        wait_for_ffi_status(id, TransferStatusEnum::Failed);
        let snap = transfer_status(id.clone()).unwrap();
        assert!(
            snap.local_path.starts_with("/tmp/rid"),
            "重试应保持原始路径"
        );
        assert!(
            snap.remote_path.starts_with("/remote/rid"),
            "重试应保持原始远端路径"
        );
    }
}
