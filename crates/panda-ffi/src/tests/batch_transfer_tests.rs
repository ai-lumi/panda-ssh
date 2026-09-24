use super::*;
use crate::test_support::global_test_lock;
use crate::ffi_transfers::reset_transfer_service_for_test;
use std::time::Duration;

fn reset() {
    reset_transfer_service_for_test();
    reset_batch_service_for_test();
}

fn wait_for_batch_status(id: &str, expected: BatchTransferStatusEnum) -> BatchTransferStatusRecord {
    for _ in 0..300 {
        if let Ok(snap) = batch_transfer_status(id.to_string()) {
            if snap.status == expected {
                return snap;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("batch task {id} did not reach {expected:?} in time");
}

// ---------------------------------------------------------------------------
// 类型转换
// ---------------------------------------------------------------------------

#[test]
fn direction_conversion_round_trip() {
    assert_eq!(
        from_core_direction(to_core_direction(BatchTransferDirectionEnum::Upload)),
        BatchTransferDirectionEnum::Upload
    );
    assert_eq!(
        from_core_direction(to_core_direction(BatchTransferDirectionEnum::Download)),
        BatchTransferDirectionEnum::Download
    );
}

#[test]
fn status_conversion_covers_all_variants() {
    let cases = [
        (BatchStatus::Queued, BatchTransferStatusEnum::Queued),
        (BatchStatus::Running, BatchTransferStatusEnum::Running),
        (BatchStatus::WaitingForConflict, BatchTransferStatusEnum::WaitingForConflict),
        (BatchStatus::Completed, BatchTransferStatusEnum::Completed),
        (BatchStatus::Failed, BatchTransferStatusEnum::Failed),
        (BatchStatus::Cancelled, BatchTransferStatusEnum::Cancelled),
    ];
    for (core, ffi) in cases {
        assert_eq!(from_core_status(core), ffi);
    }
}

#[test]
fn snapshot_to_record_converts_all_fields() {
    let snap = BatchTaskSnapshot {
        id: "t1".into(),
        direction: BatchDirection::Upload,
        host_id: "h1".into(),
        dest_dir: "/dest".into(),
        sources: vec!["/a".into(), "/b".into()],
        total_size: 100,
        transferred: 50,
        status: BatchStatus::Running,
        error: Some("err".into()),
        pending_conflict: Some(BatchConflictInfo {
            item_source: "src".into(),
            item_destination: "dst".into(),
            source_size: 10,
            source_mtime: Some(20),
            target_size: 30,
            target_mtime: Some(40),
        }),
    };
    let rec = snapshot_to_record(snap);
    assert_eq!(rec.id, "t1");
    assert_eq!(rec.direction, BatchTransferDirectionEnum::Upload);
    assert_eq!(rec.host_id, "h1");
    assert_eq!(rec.dest_dir, "/dest");
    assert_eq!(rec.sources, vec!["/a", "/b"]);
    assert_eq!(rec.total_size, 100);
    assert_eq!(rec.transferred, 50);
    assert_eq!(rec.status, BatchTransferStatusEnum::Running);
    assert_eq!(rec.error, Some("err".into()));
    let conflict = rec.pending_conflict.unwrap();
    assert_eq!(conflict.item_source, "src");
    assert_eq!(conflict.item_destination, "dst");
    assert_eq!(conflict.source_size, 10);
    assert_eq!(conflict.source_mtime, Some(20));
    assert_eq!(conflict.target_size, 30);
    assert_eq!(conflict.target_mtime, Some(40));
}

#[test]
fn snapshot_to_record_without_conflict() {
    let snap = BatchTaskSnapshot {
        id: "t2".into(),
        direction: BatchDirection::Download,
        host_id: "h2".into(),
        dest_dir: "/dl".into(),
        sources: vec![],
        total_size: 0,
        transferred: 0,
        status: BatchStatus::Queued,
        error: None,
        pending_conflict: None,
    };
    let rec = snapshot_to_record(snap);
    assert_eq!(rec.status, BatchTransferStatusEnum::Queued);
    assert!(rec.pending_conflict.is_none());
    assert!(rec.error.is_none());
}

#[test]
fn from_core_conflict_maps_all_fields() {
    let info = BatchConflictInfo {
        item_source: "s".into(),
        item_destination: "d".into(),
        source_size: 1,
        source_mtime: None,
        target_size: 2,
        target_mtime: None,
    };
    let rec = from_core_conflict(info);
    assert_eq!(rec.item_source, "s");
    assert_eq!(rec.item_destination, "d");
    assert_eq!(rec.source_size, 1);
    assert_eq!(rec.source_mtime, None);
    assert_eq!(rec.target_size, 2);
    assert_eq!(rec.target_mtime, None);
}

// ---------------------------------------------------------------------------
// 错误映射
// ---------------------------------------------------------------------------

#[test]
fn failed_batch_outcome_preserves_error_text_and_empty_results() {
    for error in [
        PandaError::NotInitialized.to_string(),
        PandaError::UnknownHost("host".into()).to_string(),
        PandaError::MissingPassword("host".into()).to_string(),
        panda_core::Error::Timeout.to_string(),
        "  传输失败: /目录/文件\n原始错误  ".into(),
        String::new(),
    ] {
        let outcome = failed_batch_outcome(error.clone());
        assert_failed_outcome(&outcome, &error);
    }
}

#[test]
fn failed_batch_outcome_does_not_reclassify_cancellation_errors() {
    for error in [
        PandaError::Cancelled.to_string(),
        panda_core::Error::Cancelled.to_string(),
    ] {
        let outcome = failed_batch_outcome(error.clone());
        assert_failed_outcome(&outcome, &error);
    }
}

fn assert_failed_outcome(outcome: &BatchOutcome, error: &str) {
    assert!(outcome.completed.is_empty());
    assert!(outcome.skipped.is_empty());
    assert_eq!(outcome.errors, vec![error]);
    assert!(!outcome.cancelled);
}

// 冲突解析器由核心服务创建；仅捕获真实私有执行器的结果，不替换执行行为。
struct RecordingBatchExecutor(tokio::sync::mpsc::UnboundedSender<BatchOutcome>);

impl BatchExecutor for RecordingBatchExecutor {
    fn execute(&self, ctx: &BatchContext) -> Pin<Box<dyn Future<Output = BatchOutcome> + Send>> {
        let execution = FfiBatchExecutor.execute(ctx);
        let sender = self.0.clone();
        Box::pin(async move {
            let outcome = execution.await;
            sender.send(outcome.clone()).unwrap();
            outcome
        })
    }
}

fn execute_batch_for_test(host_id: &str, direction: BatchDirection) -> BatchOutcome {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let service = BatchTransferService::new(Box::new(RecordingBatchExecutor(sender)));
    runtime().block_on(async {
        let sources = vec!["/unused/source".into()];
        let dest_dir = "/unused/destination".into();
        match direction {
            BatchDirection::Upload => {
                service.start_upload(host_id.into(), sources, dest_dir, None, None)
            }
            BatchDirection::Download => {
                service.start_download(host_id.into(), sources, dest_dir, None, None)
            }
        }
        .unwrap();
        tokio::time::timeout(Duration::from_secs(3), receiver.recv())
            .await
            .expect("私有执行器应及时返回前置失败")
            .expect("私有执行器应返回原始执行结果")
    })
}

#[test]
fn executor_unknown_host_preserves_failure_contract() {
    let _g = global_test_lock();
    reset();
    for direction in [BatchDirection::Upload, BatchDirection::Download] {
        let outcome = execute_batch_for_test("nonexistent-host", direction);
        assert_failed_outcome(&outcome, "no host with id nonexistent-host");
    }
}

#[test]
fn executor_empty_host_preserves_failure_contract() {
    let _g = global_test_lock();
    reset();
    for direction in [BatchDirection::Upload, BatchDirection::Download] {
        let outcome = execute_batch_for_test("", direction);
        assert_failed_outcome(&outcome, "no host with id ");
    }
}

#[test]
fn executor_missing_password_preserves_failure_contract() {
    let _g = global_test_lock();
    reset();
    // 既有夹具分别覆盖无凭据引用、引用存在但凭据缺失；两者均不得尝试连接。
    for host_id in ["test-host", "refused-host"] {
        for direction in [BatchDirection::Upload, BatchDirection::Download] {
            let outcome = execute_batch_for_test(host_id, direction);
            assert_failed_outcome(
                &outcome,
                &format!("host {host_id} uses password auth but no password was provided"),
            );
        }
    }
}

#[test]
fn unknown_task_returns_structured_error() {
    let _g = global_test_lock();
    reset();
    let id = uuid::Uuid::new_v4().to_string();
    assert!(matches!(
        batch_transfer_status(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        batch_transfer_cancel(id.clone()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        batch_transfer_resolve_conflict(id, true),
        Err(PandaError::UnknownTransferTask(_))
    ));
}

#[test]
fn invalid_task_id_returns_error() {
    let _g = global_test_lock();
    reset();
    assert!(batch_transfer_status("not-a-uuid".into()).is_err());
    assert!(batch_transfer_cancel("not-a-uuid".into()).is_err());
    assert!(batch_transfer_resolve_conflict("not-a-uuid".into(), true).is_err());
}

#[test]
fn start_upload_unknown_host_returns_error() {
    let _g = global_test_lock();
    reset();
    let err = start_batch_upload(
        "nonexistent-host".into(),
        vec!["/tmp/f".into()],
        "/remote".into(),
        None,
        None,
    )
    .unwrap_err();
    assert!(matches!(err, PandaError::UnknownHost(_)));
}

#[test]
fn start_download_unknown_host_returns_error() {
    let _g = global_test_lock();
    reset();
    let err = start_batch_download(
        "nonexistent-host".into(),
        vec!["/remote/f".into()],
        "/tmp".into(),
        None,
        None,
    )
    .unwrap_err();
    assert!(matches!(err, PandaError::UnknownHost(_)));
}

// ---------------------------------------------------------------------------
// 正常流程（通过真实 FfiBatchExecutor + 拒绝连接主机）
// ---------------------------------------------------------------------------

#[test]
fn start_batch_upload_reaches_failed_for_refused_host() {
    let _g = global_test_lock();
    reset();
    let id = start_batch_upload(
        "refused-host".into(),
        vec!["/tmp/test".into()],
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    let snap = wait_for_batch_status(&id, BatchTransferStatusEnum::Failed);
    assert_eq!(snap.direction, BatchTransferDirectionEnum::Upload);
    assert_eq!(snap.host_id, "refused-host");
    assert!(snap.error.is_some(), "连接拒绝应设置错误信息");
}

#[test]
fn start_batch_download_reaches_failed_for_refused_host() {
    let _g = global_test_lock();
    reset();
    let id = start_batch_download(
        "refused-host".into(),
        vec!["/remote/test".into()],
        "/tmp".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    let snap = wait_for_batch_status(&id, BatchTransferStatusEnum::Failed);
    assert_eq!(snap.direction, BatchTransferDirectionEnum::Download);
    assert!(snap.error.is_some());
}

#[test]
fn batch_transfer_list_returns_all_tasks() {
    let _g = global_test_lock();
    reset();
    let mut ids = Vec::new();
    for i in 0..3 {
        let id = start_batch_upload(
            "refused-host".into(),
            vec![format!("/tmp/f{i}")],
            format!("/remote/d{i}"),
            Some("pw".into()),
            None,
        )
        .unwrap();
        ids.push(id);
    }
    ids.sort();
    let list = batch_transfer_list().unwrap();
    assert!(list.len() >= 3);
    let mut list_ids: Vec<String> = list.iter().map(|r| r.id.clone()).collect();
    list_ids.sort();
    for id in &ids {
        assert!(list_ids.contains(id), "列表应包含任务 {id}");
    }
    for id in &ids {
        wait_for_batch_status(id, BatchTransferStatusEnum::Failed);
    }
}

#[test]
fn batch_list_empty_after_reset() {
    let _g = global_test_lock();
    reset();
    let list = batch_transfer_list().unwrap();
    assert!(list.is_empty());
}

// ---------------------------------------------------------------------------
// scan_local_batch
// ---------------------------------------------------------------------------

#[test]
fn scan_local_batch_with_files() {
    let _g = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    let f1 = dir.path().join("a.txt");
    let f2 = dir.path().join("b.txt");
    std::fs::write(&f1, b"hello").unwrap();
    std::fs::write(&f2, b"world!").unwrap();
    let items = scan_local_batch(
        vec![f1.to_string_lossy().into(), f2.to_string_lossy().into()],
        "/remote/dest".into(),
    )
    .unwrap();
    assert_eq!(items.len(), 2);
    let sizes: Vec<u64> = items.iter().map(|i| i.size).collect();
    assert!(sizes.contains(&5), "应包含 5 字节文件: sizes={sizes:?}");
    assert!(sizes.contains(&6), "应包含 6 字节文件: sizes={sizes:?}");
    assert!(!items[0].is_dir);
    assert!(!items[1].is_dir);
}

#[test]
fn scan_local_batch_with_directory() {
    let _g = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    let sub = dir.path().join("sub");
    std::fs::create_dir_all(&sub).unwrap();
    std::fs::write(sub.join("inner.txt"), b"data").unwrap();
    let items = scan_local_batch(
        vec![dir.path().to_string_lossy().into()],
        "/remote".into(),
    )
    .unwrap();
    assert!(items.len() >= 2, "应包含目录和文件");
    let dir_item = items.iter().find(|i| i.is_dir).unwrap();
    assert!(dir_item.source.contains(dir.path().file_name().unwrap().to_str().unwrap()));
    let file_item = items.iter().find(|i| !i.is_dir).unwrap();
    assert_eq!(file_item.size, 4);
}

#[test]
fn scan_local_batch_nonexistent_source_returns_error() {
    let _g = global_test_lock();
    let result = scan_local_batch(
        vec!["/nonexistent/path/xyz".into()],
        "/remote".into(),
    );
    assert!(result.is_err());
}

// ---------------------------------------------------------------------------
// 变更计数器
// ---------------------------------------------------------------------------

#[test]
fn batch_change_counter_increments_via_on_change_callback() {
    let _g = global_test_lock();
    reset();
    let before = crate::ffi_transfers::transfer_change_counter();
    let id = start_batch_upload(
        "refused-host".into(),
        vec!["/tmp/test".into()],
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    wait_for_batch_status(&id, BatchTransferStatusEnum::Failed);
    let after = crate::ffi_transfers::transfer_change_counter();
    assert!(
        after > before,
        "批量任务状态转换应通过 on_change 回调递增 FFI 计数器: before={before}, after={after}"
    );
}

// ---------------------------------------------------------------------------
// 取消
// ---------------------------------------------------------------------------

#[test]
fn cancel_failed_task_via_ffi() {
    let _g = global_test_lock();
    reset();
    let id = start_batch_upload(
        "refused-host".into(),
        vec!["/tmp/test".into()],
        "/remote".into(),
        Some("pw".into()),
        None,
    )
    .unwrap();
    wait_for_batch_status(&id, BatchTransferStatusEnum::Failed);
    batch_transfer_cancel(id.clone()).unwrap();
    let snap = batch_transfer_status(id).unwrap();
    assert_eq!(snap.status, BatchTransferStatusEnum::Failed);
}
