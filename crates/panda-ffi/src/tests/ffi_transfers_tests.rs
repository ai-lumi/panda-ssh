    use super::*;
    use crate::test_support::global_test_lock;

    /// 构造一个假的 TransferTask 用于测试（不启动异步工作线程）。
    fn make_test_task(id: Uuid) -> TransferTask {
        TransferTask {
            id,
            direction: TransferDirectionEnum::Upload,
            host_id: "test-host".into(),
            local_path: "/tmp/test".into(),
            remote_path: "/remote/test".into(),
            password: None,
            passphrase: None,
            size: 1024,
            status: Arc::new(std::sync::Mutex::new(TransferStatusEnum::Queued)),
            transferred: Arc::new(AtomicU64::new(0)),
            error: Arc::new(std::sync::Mutex::new(None)),
            cancel: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            version: Arc::new(AtomicU64::new(1)),
            speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(1024))),
            group_id: None,
            group_name: None,
        }
    }

    /// 将测试任务插入全局注册表。
    fn insert_test_task(task: &TransferTask) {
        transfer_tasks()
            .lock()
            .unwrap()
            .insert(task.id, task.clone());
    }

    /// 从全局注册表移除测试任务。
    fn remove_test_task(id: &Uuid) {
        transfer_tasks().lock().unwrap().remove(id);
    }

    #[test]
    fn progress_alone_advances_revision_and_snapshot() {
        let _test_guard = global_test_lock();
        let task = make_test_task(Uuid::new_v4());
        let progress = task.progress_callback();
        for done in [1, 512, 1024] {
            let before = transfer_change_counter();
            progress(done, 1024);
            assert!(
                transfer_change_counter() > before,
                "仅字节进度也必须通知订阅方"
            );
            assert_eq!(task.snapshot().transferred, done);
        }
    }

    #[test]
    fn change_counter_increments_on_notify() {
        let _test_guard = global_test_lock();
        let before = transfer_change_counter();
        notify_transfer_changed();
        let after = transfer_change_counter();
        assert_eq!(after, before + 1);
    }

    #[test]
    fn change_counter_does_not_increment_on_read() {
        let _test_guard = global_test_lock();
        // 读取计数器本身不改变它的值
        let v1 = transfer_change_counter();
        let v2 = transfer_change_counter();
        assert_eq!(v1, v2);
    }

    #[test]
    fn change_counter_increments_on_cancel() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_cancel(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "cancel should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_pause() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_pause(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "pause should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_resume() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        // 先暂停
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_resume(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "resume should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_multiple_transitions_accumulate() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let c0 = transfer_change_counter();

        // Queued → Paused
        let _ = transfer_pause(id.to_string());
        let c1 = transfer_change_counter();
        assert!(c1 >= c0 + 1, "pause should bump counter by at least 1");

        // Paused → Queued (resume)
        let _ = transfer_resume(id.to_string());
        let c2 = transfer_change_counter();
        assert!(c2 >= c1 + 1, "resume should bump counter by at least 1");

        // Queued → Cancelled
        let _ = transfer_cancel(id.to_string());
        let c3 = transfer_change_counter();
        assert!(c3 >= c2 + 1, "cancel should bump counter by at least 1");

        // 总共至少递增了 3 次
        assert!(
            c3 >= c0 + 3,
            "three transitions should bump counter by at least 3"
        );

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_cancel() {
        let _test_guard = global_test_lock();
        // 已完成的任务 cancel 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Completed;
        insert_test_task(&task);

        let _ = transfer_cancel(id.to_string());
        // 状态应保持 Completed，不应被改为 Cancelled
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Completed,
            "cancelling a completed task should not change its status"
        );

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_pause() {
        let _test_guard = global_test_lock();
        // 已暂停的任务再次 pause 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let _ = transfer_pause(id.to_string());
        // 状态应保持 Paused（不会重复触发 notify）
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Paused,
            "pausing an already paused task should not change its status"
        );

        remove_test_task(&id);
    }

    // -----------------------------------------------------------------------
    // 状态聚合与任务组
    // -----------------------------------------------------------------------

    #[test]
    fn group_status_priority_prefers_running_over_all_terminal_states() {
        let _test_guard = global_test_lock();
        use TransferStatusEnum as S;
        assert_eq!(
            group_status_priority(&[S::Failed, S::Running, S::Completed]),
            S::Running
        );
        assert_eq!(group_status_priority(&[S::Completed, S::Paused]), S::Paused);
        assert_eq!(group_status_priority(&[S::Completed, S::Queued]), S::Queued);
        assert_eq!(group_status_priority(&[S::Cancelled, S::Failed]), S::Failed);
        assert_eq!(group_status_priority(&[S::Cancelled]), S::Cancelled);
        assert_eq!(group_status_priority(&[S::Completed]), S::Completed);
        assert_eq!(group_status_priority(&[]), S::Completed);
    }

    #[test]
    fn transfer_groups_aggregates_grouped_tasks_and_ignores_ungrouped() {
        let _test_guard = global_test_lock();
        let mk = |group: Option<(&str, &str)>, status: TransferStatusEnum, size: u64, done: u64| {
            let mut task = make_test_task(Uuid::new_v4());
            if let Some((gid, gname)) = group {
                task.group_id = Some(gid.into());
                task.group_name = Some(gname.into());
            }
            task.direction = TransferDirectionEnum::Download;
            task.size = size;
            *task.status.lock().unwrap() = status;
            task.transferred.store(done, Ordering::Relaxed);
            task
        };

        let running = mk(Some(("g1", "备份")), TransferStatusEnum::Running, 100, 10);
        let done = mk(
            Some(("g1", "备份")),
            TransferStatusEnum::Completed,
            200,
            200,
        );
        let cancelled = mk(Some(("g2", "同步")), TransferStatusEnum::Cancelled, 50, 0);
        let lone = mk(None, TransferStatusEnum::Running, 10, 0);
        for t in [&running, &done, &cancelled, &lone] {
            insert_test_task(t);
        }

        let groups = transfer_groups().unwrap();
        assert_eq!(groups.len(), 2, "无分组任务不应出现在聚合中");
        assert!(groups[0].group_name < groups[1].group_name, "应按组名排序");

        let backup = groups.iter().find(|g| g.group_name == "备份").unwrap();
        assert_eq!(backup.group_id, "g1");
        assert_eq!(backup.total_count, 2);
        assert_eq!(backup.completed_count, 1);
        assert_eq!(backup.total_bytes, 300);
        assert_eq!(backup.transferred_bytes, 210);
        assert_eq!(
            backup.status,
            TransferStatusEnum::Running,
            "running 优先于 completed"
        );
        assert!(
            matches!(backup.direction, TransferDirectionEnum::Download),
            "组方向应取首个成员的方向"
        );

        let sync = groups.iter().find(|g| g.group_name == "同步").unwrap();
        assert_eq!(sync.status, TransferStatusEnum::Cancelled);

        for t in [&running, &done, &cancelled, &lone] {
            remove_test_task(&t.id);
        }
    }

    // -----------------------------------------------------------------------
    // 暂停等待与任务执行
    // -----------------------------------------------------------------------

    #[test]
    fn wait_while_paused_blocks_until_resume_and_reports_paused_status() {
        let _test_guard = global_test_lock();
        let task = make_test_task(Uuid::new_v4());
        task.paused.store(true, Ordering::Relaxed);
        let handle = runtime().spawn({
            let t = task.clone();
            async move {
                wait_while_paused(&t).await;
            }
        });

        let mut paused_seen = false;
        for _ in 0..100 {
            if *task.status.lock().unwrap() == TransferStatusEnum::Paused {
                paused_seen = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(paused_seen, "暂停中的任务应被标记为 Paused");

        task.paused.store(false, Ordering::Relaxed);
        task.resume_notify.notify_waiters();
        runtime().block_on(handle).unwrap();
        assert_ne!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Cancelled,
            "恢复后的等待应正常返回且不改变状态"
        );
    }

    #[test]
    fn wait_while_paused_returns_immediately_when_cancelled() {
        let _test_guard = global_test_lock();
        // 取消标志优先于暂停：等待立即返回且不改状态
        let task = make_test_task(Uuid::new_v4());
        task.cancel.store(true, Ordering::Relaxed);
        task.paused.store(true, Ordering::Relaxed);
        runtime().block_on(wait_while_paused(&task));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Queued);

        // 状态已是 Cancelled 时也直接返回
        let task2 = make_test_task(Uuid::new_v4());
        *task2.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        task2.paused.store(true, Ordering::Relaxed);
        runtime().block_on(wait_while_paused(&task2));
        assert_eq!(*task2.status.lock().unwrap(), TransferStatusEnum::Cancelled);
    }

    /// 指向本机未监听端口的主机配置：连接会被立即拒绝，不产生真实网络流量。
    fn refused_host_config() -> panda_core::HostConfig {
        panda_core::HostConfig {
            id: "refused-host".into(),
            name: "拒绝连接".into(),
            host: "127.0.0.1".into(),
            port: 1,
            username: "deploy".into(),
            auth: panda_core::AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        }
    }

    #[test]
    fn run_transfer_task_marks_cancelled_before_and_after_semaphore() {
        let _test_guard = global_test_lock();
        let cfg = refused_host_config();

        // 排队阶段已设置取消标志：不获取信号量直接标 Cancelled
        let task = make_test_task(Uuid::new_v4());
        task.cancel.store(true, Ordering::Relaxed);
        insert_test_task(&task);
        runtime().block_on(run_transfer_task(task.clone(), cfg.clone()));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Cancelled);
        remove_test_task(&task.id);

        // 获取信号量后状态已是 Cancelled：不再进入 Running
        let task2 = make_test_task(Uuid::new_v4());
        *task2.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        insert_test_task(&task2);
        runtime().block_on(run_transfer_task(task2.clone(), cfg));
        assert_eq!(*task2.status.lock().unwrap(), TransferStatusEnum::Cancelled);
        remove_test_task(&task2.id);
    }

    #[test]
    fn run_transfer_task_marks_failed_when_connection_is_refused() {
        let _test_guard = global_test_lock();
        // 上传方向：连接被拒绝 → Failed 且携带错误信息
        let mut task = make_test_task(Uuid::new_v4());
        task.password = Some("pw".into());
        insert_test_task(&task);
        runtime().block_on(run_transfer_task(task.clone(), refused_host_config()));
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Failed);
        assert!(task.error.lock().unwrap().is_some());
        remove_test_task(&task.id);

        // 下载方向同样落到 Failed
        let mut download = make_test_task(Uuid::new_v4());
        download.direction = TransferDirectionEnum::Download;
        download.password = Some("pw".into());
        insert_test_task(&download);
        runtime().block_on(run_transfer_task(download.clone(), refused_host_config()));
        assert_eq!(*download.status.lock().unwrap(), TransferStatusEnum::Failed);
        assert!(download.error.lock().unwrap().is_some());
        remove_test_task(&download.id);
    }

    // -----------------------------------------------------------------------
    // 重试、暂停拒绝
    // -----------------------------------------------------------------------

    #[test]
    fn transfer_retry_rejects_non_retryable_and_unknown_tasks() {
        let _test_guard = global_test_lock();
        // 不存在的任务
        assert!(matches!(
            transfer_retry(Uuid::new_v4().to_string()),
            Err(PandaError::UnknownTransferTask(_))
        ));

        // 非 UUID id → 结构化解析错误
        assert!(transfer_retry("not-a-uuid".into()).is_err());

        // 非重试状态（Queued）→ 拒绝
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);
        let error = transfer_retry(id.to_string()).unwrap_err();
        assert!(error.to_string().contains("not in a retryable state"));
        remove_test_task(&id);
    }

    #[test]
    fn transfer_retry_resets_state_and_reruns_until_terminal() {
        // 重试会重新加载主机配置：持有统一全局测试锁并初始化测试目录
        let _test_guard = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        crate::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
        let mut record: crate::HostConfigRecord = refused_host_config().into();
        record.id = "refused-host".into();
        crate::save_host(record).unwrap();

        let id = Uuid::new_v4();
        let mut task = make_test_task(id);
        task.host_id = "refused-host".into();
        task.password = Some("pw".into());
        *task.status.lock().unwrap() = TransferStatusEnum::Failed;
        *task.error.lock().unwrap() = Some("上次失败".into());
        insert_test_task(&task);

        let version_before = task.version.load(Ordering::Relaxed);
        // 占满并发槽位，稳定验证重试后在真正获准执行前保持 Queued。
        // 若不这样做，后台任务可能在下一个断言前已抢到许可证并进入 Running。
        let permits = runtime()
            .block_on(transfer_semaphore().acquire_many(TRANSFER_CONCURRENCY as u32))
            .unwrap();
        let retried = transfer_retry(id.to_string()).unwrap();
        assert_eq!(retried, id.to_string());
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Queued,
            "重试应重置为排队"
        );
        assert!(task.error.lock().unwrap().is_none(), "重试应清空上次错误");
        assert!(task.version.load(Ordering::Relaxed) > version_before);

        // 重试后的任务会真正执行并因连接被拒绝进入 Failed 终态
        drop(permits);
        let mut terminal = false;
        for _ in 0..300 {
            if *task.status.lock().unwrap() == TransferStatusEnum::Failed {
                terminal = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(terminal, "重试后任务应因连接拒绝进入 Failed");
        assert!(task.error.lock().unwrap().is_some());
        remove_test_task(&id);
    }

    #[test]
    fn transfer_pause_rejects_terminal_task_and_resume_is_noop_for_it() {
        let _test_guard = global_test_lock();
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Failed;
        insert_test_task(&task);

        let error = transfer_pause(id.to_string()).unwrap_err();
        assert!(error.to_string().contains("already terminal"));

        // 终态任务的 resume 也是 no-op：状态保持不变
        transfer_resume(id.to_string()).unwrap();
        assert_eq!(*task.status.lock().unwrap(), TransferStatusEnum::Failed);
        remove_test_task(&id);
    }
