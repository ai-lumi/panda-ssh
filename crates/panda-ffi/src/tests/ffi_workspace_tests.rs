    use super::*;
    use crate::test_support::global_test_lock;
    use crate::test_support::GlobalTestGuard;

    fn reset_workspace() -> GlobalTestGuard {
        let guard = global_test_lock();
        workspace_reset();
        guard
    }

    fn unique_tab_id(prefix: &str) -> String {
        format!("{}-{}", prefix, Uuid::new_v4())
    }

    /// 辅助：创建带主机名映射的 WorkspaceState。
    fn make_state(names: &[(&str, &str)]) -> WorkspaceState {
        let mappings: Vec<HostNameMapping> = names
            .iter()
            .map(|(id, name)| HostNameMapping {
                host_id: id.to_string(),
                name: name.to_string(),
            })
            .collect();
        let mut state = WorkspaceState::new();
        state.update_host_names(mappings);
        state
    }

    #[test]
    fn workspace_open_tab_creates_tab_with_disambiguated_title() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp).unwrap();
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        let list = state.tab_list();
        assert_eq!(list.len(), 3);
        assert_eq!(list[0].title, "server");
        assert_eq!(list[1].title, "server (2)");
        assert_eq!(list[2].title, "server (3)");
        assert_eq!(list[0].id, id1);
        assert_eq!(list[1].id, id2);
        assert_eq!(list[2].id, id3);
        assert_eq!(list[0].kind, panda_core::TabKind::Terminal);
        assert_eq!(
            list[0].connection_status,
            panda_core::ConnectionStatus::Connecting
        );
    }

    #[test]
    fn workspace_close_tab_preserves_remaining_titles() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        state.request_close(&id1);

        let list = state.tab_list();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].title, "server (2)");
        assert_eq!(list[1].title, "server (3)");
        assert!(list.iter().any(|t| t.id == id3));

        state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        assert_eq!(state.tab_list()[2].title, "server");
    }

    #[test]
    fn workspace_close_active_tab_selects_neighbor() {
        let mut state = make_state(&[("h1", "server")]);
        let _id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        assert_eq!(state.active_tab_id(), Some(id3.clone()));

        state.request_close(&id3);
        assert_eq!(state.active_tab_id(), Some(id2.clone()));
    }

    #[test]
    fn workspace_host_connection_status_aggregates_with_priority() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Connecting
        );

        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);
        state.report_connection_status(&id2, panda_core::ConnectionStatus::Failed);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Connected
        );

        state.report_connection_status(&id1, panda_core::ConnectionStatus::Failed);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Failed
        );

        state.request_close(&id1);
        state.request_close(&id2);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Inactive
        );
    }

    #[test]
    fn workspace_close_connected_terminal_triggers_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close(&id1);

        assert_eq!(state.tab_list().len(), 1);

        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.tab_ids, vec![id1.clone()]);
        assert_eq!(pending.connected_terminal_count, 1);

        state.confirm_close();
        assert!(state.tab_list().is_empty());
        assert!(state.pending_close_info().is_none());
    }

    #[test]
    fn workspace_cancel_close_preserves_tab() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close(&id1);
        assert!(state.pending_close_info().is_some());

        state.cancel_close();
        assert!(state.pending_close_info().is_none());

        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_close_sftp_tab_does_not_require_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Sftp).unwrap();
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close(&id1);
        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_all_with_connected_terminals_triggers_batch_confirmation() {
        let mut state = make_state(&[("h1", "server"), ("h2", "other")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id3 = state.open_tab("h2".into(), panda_core::TabKind::Sftp).unwrap();

        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close_all();

        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.connected_terminal_count, 1);
        assert_eq!(pending.tab_ids.len(), 3);

        state.confirm_close();
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_all_without_connected_terminals_closes_immediately() {
        let mut state = make_state(&[("h1", "server")]);
        let _id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp).unwrap();

        state.request_close_all();

        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_others_with_connected_terminals_triggers_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        state.report_connection_status(&id2, panda_core::ConnectionStatus::Connected);

        state.request_close_others(&id1);

        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.connected_terminal_count, 1);
        assert!(pending.tab_ids.contains(&id2));
        assert!(pending.tab_ids.contains(&id3));
        assert!(!pending.tab_ids.contains(&id1));

        state.confirm_close();
        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_close_others_without_connected_closes_immediately() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp).unwrap();

        state.request_close_others(&id1);

        assert!(state.pending_close_info().is_none());
        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_select_tab_updates_active() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        assert_eq!(state.active_tab_id(), Some(id2.clone()));

        state.select_tab(&id1);
        assert_eq!(state.active_tab_id(), Some(id1.clone()));
    }

    #[test]
    fn workspace_disconnected_terminal_closes_without_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Failed);

        state.request_close(&id1);
        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_unknown_host_uses_host_id_as_title() {
        let mut state = make_state(&[]);
        let _id1 = state.open_tab("unknown-host-id".into(), panda_core::TabKind::Terminal).unwrap();
        let list = state.tab_list();
        assert_eq!(list[0].title, "unknown-host-id");
    }

    #[test]
    fn workspace_close_first_tab_selects_right_neighbor() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        state.select_tab(&id1);
        state.request_close(&id1);
        assert_eq!(state.active_tab_id(), Some(id2.clone()));
    }

    #[test]
    fn workspace_batch_close_confirmed_by_confirm_close() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close_all();
        assert!(state.pending_close_info().is_some());

        let info = state.pending_close_info();
        assert!(info.is_some());
        assert!(info.unwrap().is_batch);

        state.confirm_close();
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_multiple_hosts_independent_numbering() {
        let mut state = make_state(&[("h1", "alpha"), ("h2", "beta")]);
        let _t1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();
        let _t2 = state.open_tab("h2".into(), panda_core::TabKind::Terminal).unwrap();
        let _t3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal).unwrap();

        let list = state.tab_list();
        assert_eq!(list[0].title, "alpha");
        assert_eq!(list[1].title, "beta");
        assert_eq!(list[2].title, "alpha (2)");
    }

    // -----------------------------------------------------------------------
    // Terminal session tests
    // -----------------------------------------------------------------------

    #[test]
    fn terminal_session_register_creates_connecting_session() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("register");
        let record = terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(record.id, tab_id);
        assert_eq!(record.host_id, "host-1");
        assert_eq!(record.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(record.attempt, 0);
        assert_eq!(record.failure_category, None);
        assert_eq!(record.failure_message, None);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_phase_return_current_phase() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("phase");
        terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(
            terminal_session_phase(tab_id.clone()),
            Some(TerminalPhaseEnum::Connecting)
        );

        terminal_session_transition_to_shell(tab_id.clone());
        assert_eq!(
            terminal_session_phase(tab_id.clone()),
            Some(TerminalPhaseEnum::Shell)
        );
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_phase_returns_none_for_unknown_tab() {
        let _test_guard = reset_workspace();
        assert_eq!(terminal_session_phase(unique_tab_id("nonexistent")), None);
    }

    #[test]
    fn terminal_session_transition_to_shell_from_connecting() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("to-shell");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_shell(tab_id.clone());

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Shell);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_transition_to_shell_from_shell_is_noop() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("noop-shell");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_shell(tab_id.clone());
        terminal_session_transition_to_shell(tab_id.clone());

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Shell);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_transition_to_failed_records_error() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("fail");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "连接超时".into(),
        );

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Failed);
        assert_eq!(
            record.failure_category,
            Some(TerminalFailureCategoryEnum::Timeout)
        );
        assert_eq!(record.failure_message, Some("连接超时".into()));
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_retry_increments_attempt() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("retry");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::AuthFailed,
            "认证失败".into(),
        );

        let retry = terminal_session_retry(tab_id.clone()).unwrap();
        assert_eq!(retry.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(retry.attempt, 1);
        assert_eq!(retry.failure_category, None);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_retry_from_connecting_returns_none() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("retry-connecting");
        terminal_session_register("host-1".into(), tab_id.clone());
        assert!(terminal_session_retry(tab_id.clone()).is_none());
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_close_removes_session() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("close");
        terminal_session_register("host-1".into(), tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_some());

        terminal_session_close(tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_none());
    }

    #[test]
    fn terminal_session_is_stale_detects_outdated_generation() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("stale");
        let record = terminal_session_register("host-1".into(), tab_id.clone());
        let gen0 = record.attempt;

        assert!(!terminal_session_is_stale(tab_id.clone(), gen0));

        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "超时".into(),
        );
        terminal_session_retry(tab_id.clone());

        assert!(terminal_session_is_stale(tab_id.clone(), gen0));
        assert!(!terminal_session_is_stale(tab_id.clone(), 1));
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_is_stale_returns_true_for_unknown_tab() {
        let _test_guard = reset_workspace();
        assert!(terminal_session_is_stale(
            unique_tab_id("nonexistent-stale"),
            0
        ));
    }

    #[test]
    fn terminal_session_full_lifecycle_via_ffi() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("lifecycle");

        let record = terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(record.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(record.attempt, 0);

        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "超时".into(),
        );
        let failed = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(failed.phase, TerminalPhaseEnum::Failed);
        assert_eq!(failed.attempt, 0);

        let retry = terminal_session_retry(tab_id.clone()).unwrap();
        assert_eq!(retry.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(retry.attempt, 1);

        assert!(terminal_session_is_stale(tab_id.clone(), 0));
        assert!(!terminal_session_is_stale(tab_id.clone(), 1));

        terminal_session_transition_to_shell(tab_id.clone());
        let shell = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(shell.phase, TerminalPhaseEnum::Shell);
        assert_eq!(shell.attempt, 1);

        terminal_session_close(tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_none());
    }

    #[test]
    fn terminal_session_close_via_tab_close() {
        let _test_guard = reset_workspace();
        let mut state = workspace_state().lock().unwrap();
        let tab_id = state.open_tab("host-1".into(), panda_core::TabKind::Terminal).unwrap();
        state.service.terminal_session_register("host-1".into(), tab_id.clone());
        assert!(state.service.terminal_session_get(&tab_id).is_some());

        state.request_close(&tab_id);
        assert!(state.service.terminal_session_get(&tab_id).is_none());
    }

    // -----------------------------------------------------------------------
    // 应用停机 (FFI 层)
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_shutdown_returns_summary_and_rejects_new_tabs() {
        let _guard = reset_workspace();
        let _t1 = workspace_open_tab("sh-host".into(), TabKindEnum::Terminal).unwrap();
        let _t2 = workspace_open_tab("sh-host".into(), TabKindEnum::Sftp).unwrap();
        assert!(workspace_is_accepting_new_work());

        let summary = workspace_begin_application_shutdown();

        assert_eq!(summary.closed_tab_count, 2);
        assert!(!workspace_is_accepting_new_work());
        assert!(workspace_tab_list().is_empty());
        assert!(workspace_open_tab("sh-host".into(), TabKindEnum::Terminal).is_none());
    }

    #[test]
    fn ffi_shutdown_idempotent() {
        let _guard = reset_workspace();
        let _t1 = workspace_open_tab("sh2-host".into(), TabKindEnum::Terminal).unwrap();

        let first = workspace_begin_application_shutdown();
        let second = workspace_begin_application_shutdown();

        assert_eq!(first.closed_tab_count, 1);
        assert_eq!(second.closed_tab_count, 0);
    }

    #[test]
    fn ffi_shutdown_clears_pending_close() {
        let _guard = reset_workspace();
        let tab = workspace_open_tab("sh3-host".into(), TabKindEnum::Terminal).unwrap();
        workspace_report_connection_status(tab.id.clone(), ConnectionStatusEnum::Connected);
        workspace_close_all_tabs();
        assert!(workspace_pending_close().is_some());

        workspace_begin_application_shutdown();

        assert!(workspace_pending_close().is_none());
        assert!(workspace_tab_list().is_empty());
    }

    #[test]
    fn ffi_reset_restores_accepting_new_work() {
        let _guard = reset_workspace();
        workspace_begin_application_shutdown();
        assert!(!workspace_is_accepting_new_work());

        workspace_reset();

        assert!(workspace_is_accepting_new_work());
        assert!(workspace_open_tab("restore-host".into(), TabKindEnum::Terminal).is_some());
    }

    // -----------------------------------------------------------------------
    // FFI 导出包装层（全局状态经导出函数访问）
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_enum_mappings_cover_every_core_variant() {
        use panda_core::TabKind;
        assert!(matches!(
            TabKind::from(TabKindEnum::Terminal),
            TabKind::Terminal
        ));
        assert!(matches!(TabKind::from(TabKindEnum::Sftp), TabKind::Sftp));
        assert!(matches!(
            TabKindEnum::from(TabKind::Terminal),
            TabKindEnum::Terminal
        ));
        assert!(matches!(
            TabKindEnum::from(TabKind::Sftp),
            TabKindEnum::Sftp
        ));

        for (ffi, core) in [
            (
                ConnectionStatusEnum::Inactive,
                panda_core::ConnectionStatus::Inactive,
            ),
            (
                ConnectionStatusEnum::Connecting,
                panda_core::ConnectionStatus::Connecting,
            ),
            (
                ConnectionStatusEnum::Connected,
                panda_core::ConnectionStatus::Connected,
            ),
            (
                ConnectionStatusEnum::Failed,
                panda_core::ConnectionStatus::Failed,
            ),
        ] {
            assert!(matches!(panda_core::ConnectionStatus::from(ffi), c if c == core));
            assert!(matches!(ConnectionStatusEnum::from(core), f if f == ffi));
        }

        for (ffi, core) in [
            (
                TerminalPhaseEnum::Connecting,
                panda_core::TerminalPhase::Connecting,
            ),
            (TerminalPhaseEnum::Shell, panda_core::TerminalPhase::Shell),
            (TerminalPhaseEnum::Failed, panda_core::TerminalPhase::Failed),
        ] {
            assert!(matches!(panda_core::TerminalPhase::from(ffi), p if p == core));
            assert!(matches!(TerminalPhaseEnum::from(core), f if f == ffi));
        }

        for (ffi, core) in [
            (
                TerminalFailureCategoryEnum::Timeout,
                panda_core::TerminalFailureCategory::Timeout,
            ),
            (
                TerminalFailureCategoryEnum::AuthFailed,
                panda_core::TerminalFailureCategory::AuthFailed,
            ),
            (
                TerminalFailureCategoryEnum::MissingCredential,
                panda_core::TerminalFailureCategory::MissingCredential,
            ),
            (
                TerminalFailureCategoryEnum::HostKeyMismatch,
                panda_core::TerminalFailureCategory::HostKeyMismatch,
            ),
            (
                TerminalFailureCategoryEnum::Other,
                panda_core::TerminalFailureCategory::Other,
            ),
        ] {
            assert!(matches!(panda_core::TerminalFailureCategory::from(ffi), c if c == core));
            assert!(matches!(TerminalFailureCategoryEnum::from(core), f if f == ffi));
        }
    }

    #[test]
    fn workspace_ffi_open_tab_titles_and_selection() {
        let _guard = reset_workspace();
        let host = unique_tab_id("ffi-h");

        let tab = workspace_open_tab(host.clone(), TabKindEnum::Terminal).unwrap();
        assert_eq!(tab.host_id, host);
        assert!(matches!(tab.kind, TabKindEnum::Terminal));
        assert!(matches!(
            tab.connection_status,
            ConnectionStatusEnum::Connecting
        ));
        assert_eq!(workspace_active_tab_id(), Some(tab.id.clone()));

        workspace_open_tab(host.clone(), TabKindEnum::Sftp).unwrap();
        assert_eq!(workspace_tab_list().len(), 2);

        workspace_set_host_names(vec![HostNameMapping {
            host_id: host.clone(),
            name: "别名机".into(),
        }]);
        let list = workspace_tab_list();
        // 主机名称在页签创建后更新，不得改写已有页签的稳定标题。
        assert_eq!(list[0].title, host);

        workspace_select_tab(list[1].id.clone());
        assert_eq!(workspace_active_tab_id(), Some(list[1].id.clone()));
    }

    #[test]
    fn workspace_ffi_connected_terminal_close_requires_confirmation() {
        let _guard = reset_workspace();
        let tab = workspace_open_tab("ffi-confirm-host".into(), TabKindEnum::Terminal).unwrap();
        workspace_report_connection_status(tab.id.clone(), ConnectionStatusEnum::Connected);
        assert!(matches!(
            workspace_host_connection_status("ffi-confirm-host".into()),
            ConnectionStatusEnum::Connected
        ));

        workspace_close_tab(tab.id.clone());
        let pending = workspace_pending_close().unwrap();
        assert_eq!(pending.tab_ids, vec![tab.id.clone()]);
        assert_eq!(pending.connected_terminal_count, 1);

        // 取消：标签保留、状态回 Inactive 验证聚合
        workspace_cancel_close();
        assert!(workspace_pending_close().is_none());
        assert_eq!(workspace_tab_list().len(), 1);

        // 确认：标签关闭、聚合状态回落
        workspace_close_tab(tab.id.clone());
        workspace_confirm_close();
        assert!(workspace_tab_list().is_empty());
        assert!(matches!(
            workspace_host_connection_status("ffi-confirm-host".into()),
            ConnectionStatusEnum::Inactive
        ));
    }

    #[test]
    fn workspace_ffi_confirm_close_handles_batch_and_single_paths() {
        let _guard = reset_workspace();
        let t1 = workspace_open_tab("ffi-batch-host".into(), TabKindEnum::Terminal).unwrap();
        let t2 = workspace_open_tab("ffi-batch-host".into(), TabKindEnum::Terminal).unwrap();
        workspace_report_connection_status(t1.id.clone(), ConnectionStatusEnum::Connected);

        // 关闭其他：批量确认分支
        workspace_close_other_tabs(t2.id.clone());
        let pending = workspace_pending_close().unwrap();
        assert_eq!(pending.tab_ids, vec![t1.id.clone()]);
        assert_eq!(pending.connected_terminal_count, 1);
        workspace_confirm_close();
        assert_eq!(workspace_tab_list().len(), 1);

        // 关闭全部（无已连接终端 → 立即清空，活动标签随之为空）
        workspace_report_connection_status(t2.id.clone(), ConnectionStatusEnum::Failed);
        workspace_close_all_tabs();
        assert!(workspace_tab_list().is_empty());
        assert_eq!(workspace_active_tab_id(), None);
    }

    #[test]
    fn workspace_ffi_close_all_with_connected_terminal_waits_for_confirmation() {
        let _guard = reset_workspace();
        let t1 = workspace_open_tab("ffi-all-host".into(), TabKindEnum::Terminal).unwrap();
        let _t2 = workspace_open_tab("ffi-all-host".into(), TabKindEnum::Sftp).unwrap();
        workspace_report_connection_status(t1.id.clone(), ConnectionStatusEnum::Connected);

        workspace_close_all_tabs();
        let pending = workspace_pending_close().unwrap();
        assert_eq!(pending.tab_ids.len(), 2);
        assert_eq!(pending.connected_terminal_count, 1);

        workspace_confirm_close();
        assert!(workspace_tab_list().is_empty());
    }

    #[test]
    fn terminal_session_shell_transition_ignored_from_failed_phase() {
        let _test_guard = reset_workspace();
        let tab_id = unique_tab_id("ffi-failed-shell");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "超时".into(),
        );
        // Failed 阶段的 shell 转换无效，阶段保持 Failed
        terminal_session_transition_to_shell(tab_id.clone());
        assert_eq!(
            terminal_session_phase(tab_id.clone()),
            Some(TerminalPhaseEnum::Failed)
        );
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_retry_unknown_tab_returns_none() {
        let _test_guard = reset_workspace();
        assert!(terminal_session_retry(unique_tab_id("ffi-retry-unknown")).is_none());
    }
