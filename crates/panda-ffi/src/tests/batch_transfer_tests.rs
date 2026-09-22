    use super::*;
    use crate::test_support::global_test_lock;

    fn task(status: BatchTransferStatusEnum) -> BatchTransferTask {
        BatchTransferTask {
            id: Uuid::new_v4(),
            direction: BatchTransferDirectionEnum::Upload,
            host_id: "host".into(),
            dest_dir: "/dest".into(),
            sources: vec!["source".into()],
            password: None,
            passphrase: None,
            total_size: Arc::new(AtomicU64::new(7)),
            transferred: Arc::new(AtomicU64::new(3)),
            status: Arc::new(Mutex::new(status)),
            error: Arc::new(Mutex::new(None)),
            cancel: Arc::new(AtomicBool::new(false)),
            pending_conflict: Arc::new(Mutex::new(None)),
            conflict_tx: Arc::new(Mutex::new(None)),
        }
    }

    #[test]
    fn snapshot_and_conflict_resolution_reject_invalid_states() {
        let _guard = global_test_lock();
        let queued = task(BatchTransferStatusEnum::Queued);
        let snapshot = queued.snapshot();
        assert_eq!(snapshot.total_size, 7);
        assert_eq!(snapshot.transferred, 3);
        assert_eq!(snapshot.status, BatchTransferStatusEnum::Queued);
        let id = queued.id.to_string();
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .insert(queued.id, queued);
        assert!(matches!(
            batch_transfer_resolve_conflict(id.clone(), true),
            Err(PandaError::Core(_))
        ));
        assert!(matches!(
            batch_transfer_status("invalid".into()),
            Err(PandaError::Core(_))
        ));
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .remove(&Uuid::parse_str(&id).unwrap());
    }

    #[test]
    fn conflict_resolution_requires_a_live_decision_channel() {
        let _guard = global_test_lock();
        let waiting = task(BatchTransferStatusEnum::WaitingForConflict);
        let id = waiting.id;
        batch_transfer_tasks().lock().unwrap().insert(id, waiting);
        assert!(matches!(
            batch_transfer_resolve_conflict(id.to_string(), false),
            Err(PandaError::Core(_))
        ));
        batch_transfer_tasks().lock().unwrap().remove(&id);
    }

    #[test]
    fn cancel_marks_queued_task_and_wakes_waiting_task() {
        let _guard = global_test_lock();

        let queued = task(BatchTransferStatusEnum::Queued);
        let queued_id = queued.id;
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .insert(queued_id, queued);
        batch_transfer_cancel(queued_id.to_string()).unwrap();
        let queued = batch_transfer_status(queued_id.to_string()).unwrap();
        assert_eq!(queued.status, BatchTransferStatusEnum::Cancelled);
        batch_transfer_tasks().lock().unwrap().remove(&queued_id);

        let waiting = task(BatchTransferStatusEnum::WaitingForConflict);
        let waiting_id = waiting.id;
        let (tx, rx) = tokio::sync::oneshot::channel();
        *waiting.conflict_tx.lock().unwrap() = Some(tx);
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .insert(waiting_id, waiting);
        batch_transfer_cancel(waiting_id.to_string()).unwrap();
        assert_eq!(rx.blocking_recv().unwrap(), ConflictResolution::Skip);
        let waiting = batch_transfer_status(waiting_id.to_string()).unwrap();
        assert_eq!(waiting.status, BatchTransferStatusEnum::WaitingForConflict);
        batch_transfer_tasks().lock().unwrap().remove(&waiting_id);
    }

    #[test]
    fn conflict_resolution_sends_selected_decision_and_clears_snapshot() {
        let _guard = global_test_lock();

        for (overwrite, expected) in [
            (true, ConflictResolution::Overwrite),
            (false, ConflictResolution::Skip),
        ] {
            let waiting = task(BatchTransferStatusEnum::WaitingForConflict);
            let id = waiting.id;
            *waiting.pending_conflict.lock().unwrap() = Some(BatchConflictRecord {
                item_source: "source".into(),
                item_destination: "destination".into(),
                source_size: 1,
                source_mtime: Some(2),
                target_size: 3,
                target_mtime: Some(4),
            });
            let (tx, rx) = tokio::sync::oneshot::channel();
            *waiting.conflict_tx.lock().unwrap() = Some(tx);
            batch_transfer_tasks().lock().unwrap().insert(id, waiting);

            batch_transfer_resolve_conflict(id.to_string(), overwrite).unwrap();
            assert_eq!(rx.blocking_recv().unwrap(), expected);
            let status = batch_transfer_status(id.to_string()).unwrap();
            assert_eq!(status.status, BatchTransferStatusEnum::Running);
            assert!(status.pending_conflict.is_none());
            batch_transfer_tasks().lock().unwrap().remove(&id);
        }
    }

    #[test]
    fn conflict_resolution_reports_closed_channel_after_updating_snapshot() {
        let _guard = global_test_lock();
        let waiting = task(BatchTransferStatusEnum::WaitingForConflict);
        let id = waiting.id;
        let (tx, rx) = tokio::sync::oneshot::channel();
        drop(rx);
        *waiting.conflict_tx.lock().unwrap() = Some(tx);
        batch_transfer_tasks().lock().unwrap().insert(id, waiting);

        assert!(matches!(
            batch_transfer_resolve_conflict(id.to_string(), true),
            Err(PandaError::Core(_))
        ));
        assert_eq!(
            batch_transfer_status(id.to_string()).unwrap().status,
            BatchTransferStatusEnum::Running
        );
        batch_transfer_tasks().lock().unwrap().remove(&id);
    }

    #[test]
    fn list_orders_task_snapshots_and_cancel_rejects_unknown_task() {
        let _guard = global_test_lock();
        let mut later = task(BatchTransferStatusEnum::Running);
        later.id = Uuid::from_u128(2);
        let mut earlier = task(BatchTransferStatusEnum::Completed);
        earlier.id = Uuid::from_u128(1);
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .insert(later.id, later);
        batch_transfer_tasks()
            .lock()
            .unwrap()
            .insert(earlier.id, earlier);

        let records = batch_transfer_list().unwrap();
        let relevant: Vec<_> = records
            .into_iter()
            .filter(|record| {
                record.id == Uuid::from_u128(1).to_string()
                    || record.id == Uuid::from_u128(2).to_string()
            })
            .collect();
        assert_eq!(
            relevant
                .iter()
                .map(|record| record.id.as_str())
                .collect::<Vec<_>>(),
            vec![
                Uuid::from_u128(1).to_string(),
                Uuid::from_u128(2).to_string()
            ]
        );
        assert!(matches!(
            batch_transfer_cancel(Uuid::new_v4().to_string()),
            Err(PandaError::UnknownTransferTask(_))
        ));
        let mut tasks = batch_transfer_tasks().lock().unwrap();
        tasks.remove(&Uuid::from_u128(1));
        tasks.remove(&Uuid::from_u128(2));
    }
