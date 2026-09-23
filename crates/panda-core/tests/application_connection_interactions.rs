use panda_core::{
    AuthMethod, ConnectionCredentialPreparation, CredentialIntent, HostConfig, HostSaveRequest,
    PandaCore,
};

fn password_host(id: &str) -> HostConfig {
    HostConfig {
        id: id.into(),
        name: "测试主机".into(),
        host: "example.test".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethod::Password { password_ref: None },
        notes: None,
        group_id: None,
    }
}

#[test]
fn missing_credential_creates_request_and_response_is_bound_to_its_session() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host(password_host("host-a")).unwrap();

    let request = match core
        .prepare_connection_credentials("session-a", "host-a", None)
        .unwrap()
    {
        ConnectionCredentialPreparation::NeedsInput(request) => request,
        other => panic!("expected input request, got {other:?}"),
    };
    assert_eq!(request.session_id, "session-a");
    assert_eq!(request.host_id, "host-a");

    let result = core
        .respond_connection_credential(&request.id, "手动密码")
        .unwrap();
    assert!(matches!(result, ConnectionCredentialPreparation::Ready(_)));
}

#[test]
fn unknown_request_and_empty_input_are_rejected_without_restoring_a_session() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host(password_host("host-a")).unwrap();
    let request = match core
        .prepare_connection_credentials("session-a", "host-a", None)
        .unwrap()
    {
        ConnectionCredentialPreparation::NeedsInput(request) => request,
        other => panic!("expected input request, got {other:?}"),
    };

    assert!(core
        .respond_connection_credential("unknown-request", "密码")
        .is_err());
    assert!(core.respond_connection_credential(&request.id, "").is_err());
    assert!(core
        .respond_connection_credential(&request.id, "密码")
        .is_ok());
}

#[test]
fn cancellation_or_retry_invalidates_late_input_without_affecting_the_new_request() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host(password_host("host-a")).unwrap();
    let old_request = match core
        .prepare_connection_credentials("session-a", "host-a", None)
        .unwrap()
    {
        ConnectionCredentialPreparation::NeedsInput(request) => request,
        other => panic!("expected input request, got {other:?}"),
    };

    core.cancel_connection_interactions("session-a");
    let new_request = match core
        .prepare_connection_credentials("session-a", "host-a", None)
        .unwrap()
    {
        ConnectionCredentialPreparation::NeedsInput(request) => request,
        other => panic!("expected input request, got {other:?}"),
    };
    assert_ne!(old_request.id, new_request.id);
    assert!(core
        .respond_connection_credential(&old_request.id, "迟到密码")
        .is_err());
    assert!(core
        .respond_connection_credential(&new_request.id, "新密码")
        .is_ok());
}

#[test]
fn same_host_sessions_do_not_share_manual_input() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host_with_credentials(HostSaveRequest {
        host: password_host("host-a"),
        password: CredentialIntent::Set("已保存密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();

    let session_a = core
        .prepare_connection_credentials("session-a", "host-a", Some("会话 A 密码"))
        .unwrap();
    let session_b = core
        .prepare_connection_credentials("session-b", "host-a", None)
        .unwrap();

    assert!(matches!(
        session_a,
        ConnectionCredentialPreparation::Ready(panda_core::ConnectionCredentials::Available {
            password: Some(ref password),
            ..
        }) if password == "会话 A 密码"
    ));
    assert!(matches!(
        session_b,
        ConnectionCredentialPreparation::Ready(panda_core::ConnectionCredentials::Available {
            password: Some(ref password),
            ..
        }) if password == "已保存密码"
    ));
}
