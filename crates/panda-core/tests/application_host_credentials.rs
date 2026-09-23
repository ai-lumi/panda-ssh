use panda_core::{
    AuthMethod, ConfigStore, ConnectionCredentials, CredentialIntent, HostConfig, HostSaveRequest,
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
fn save_host_with_credentials_sets_updates_and_preserves_password() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    let host = password_host("host-a");

    core.save_host_with_credentials(HostSaveRequest {
        host: host.clone(),
        password: CredentialIntent::Set("首次密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    assert_eq!(
        core.credential_store()
            .get("host.host-a.password")
            .unwrap()
            .as_deref(),
        Some("首次密码")
    );

    core.save_host_with_credentials(HostSaveRequest {
        host: HostConfig {
            name: "已编辑主机".into(),
            ..host.clone()
        },
        password: CredentialIntent::Preserve,
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    let stored = core.config_store().get("host-a").unwrap().unwrap();
    assert_eq!(stored.name, "已编辑主机");
    assert!(matches!(
        stored.auth,
        AuthMethod::Password { password_ref: Some(ref reference) }
            if reference == "host.host-a.password"
    ));
    assert_eq!(
        core.credential_store()
            .get("host.host-a.password")
            .unwrap()
            .as_deref(),
        Some("首次密码")
    );
}

#[test]
fn save_host_with_credentials_rejects_empty_id_or_secret_without_writing_config() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();

    let error = core
        .save_host_with_credentials(HostSaveRequest {
            host: password_host(""),
            password: CredentialIntent::Set("密码".into()),
            passphrase: CredentialIntent::Remove,
        })
        .unwrap_err();
    assert!(error.to_string().contains("id"));

    let error = core
        .save_host_with_credentials(HostSaveRequest {
            host: password_host("host-a"),
            password: CredentialIntent::Set(String::new()),
            passphrase: CredentialIntent::Remove,
        })
        .unwrap_err();
    assert!(error.to_string().contains("不能为空"));
    assert!(core.list_hosts().unwrap().is_empty());
}

#[test]
fn switching_authentication_removes_obsolete_credential_references() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    let host = password_host("host-a");
    core.save_host_with_credentials(HostSaveRequest {
        host: host.clone(),
        password: CredentialIntent::Set("密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();

    core.save_host_with_credentials(HostSaveRequest {
        host: HostConfig {
            auth: AuthMethod::PublicKey {
                key_path: "/tmp/id_ed25519".into(),
                passphrase_ref: None,
            },
            ..host
        },
        password: CredentialIntent::Remove,
        passphrase: CredentialIntent::Set("口令".into()),
    })
    .unwrap();

    assert_eq!(
        core.credential_store().get("host.host-a.password").unwrap(),
        None
    );
    assert_eq!(
        core.credential_store()
            .get("host.host-a.passphrase")
            .unwrap()
            .as_deref(),
        Some("口令")
    );
}

#[test]
fn failed_config_write_restores_the_credential_written_for_the_attempt() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    let host = password_host("host-a");
    core.save_host_with_credentials(HostSaveRequest {
        host: host.clone(),
        password: CredentialIntent::Set("旧密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();

    // 将配置目标替换为目录，模拟配置写入阶段失败；凭据不能保留本次尝试写入的值。
    std::fs::remove_file(directory.path().join("hosts.toml")).unwrap();
    std::fs::create_dir(directory.path().join("hosts.toml")).unwrap();
    assert!(core
        .save_host_with_credentials(HostSaveRequest {
            host,
            password: CredentialIntent::Set("新密码".into()),
            passphrase: CredentialIntent::Remove,
        })
        .is_err());
    assert_eq!(
        core.credential_store()
            .get("host.host-a.password")
            .unwrap()
            .as_deref(),
        Some("旧密码")
    );
}

#[test]
fn delete_host_with_credentials_removes_only_the_deleted_hosts_references() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    let host = password_host("host-a");
    core.save_host_with_credentials(HostSaveRequest {
        host,
        password: CredentialIntent::Set("密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    core.credential_store()
        .save("other.password".into(), "保留".into())
        .unwrap();

    assert!(core.delete_host_with_credentials("host-a").unwrap().deleted);
    assert!(core.list_hosts().unwrap().is_empty());
    assert_eq!(
        core.credential_store().get("host.host-a.password").unwrap(),
        None
    );
    assert_eq!(
        core.credential_store()
            .get("other.password")
            .unwrap()
            .as_deref(),
        Some("保留")
    );
    assert!(
        !core
            .delete_host_with_credentials("unknown")
            .unwrap()
            .deleted
    );
}

#[test]
fn copy_host_does_not_reuse_the_source_credential_reference() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host_with_credentials(HostSaveRequest {
        host: password_host("host-a"),
        password: CredentialIntent::Set("密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();

    let copy = core.copy_host("host-a").unwrap();
    assert_ne!(copy.id, "host-a");
    assert!(matches!(
        copy.auth,
        AuthMethod::Password { password_ref: None }
    ));
    assert_eq!(core.list_hosts().unwrap().len(), 2);
}

#[test]
fn failed_host_delete_restores_deleted_credentials() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host_with_credentials(HostSaveRequest {
        host: password_host("host-a"),
        password: CredentialIntent::Set("密码".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    std::fs::remove_file(directory.path().join("hosts.toml")).unwrap();
    std::fs::create_dir(directory.path().join("hosts.toml")).unwrap();

    assert!(core.delete_host_with_credentials("host-a").is_err());
    assert_eq!(
        core.credential_store()
            .get("host.host-a.password")
            .unwrap()
            .as_deref(),
        Some("密码")
    );
}

#[test]
fn core_connection_credentials_prefer_manual_input_and_handle_missing_values() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host_with_credentials(HostSaveRequest {
        host: password_host("host-a"),
        password: CredentialIntent::Set("已保存".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    assert_eq!(
        core.resolve_connection_credentials("host-a", Some("手动"))
            .unwrap(),
        ConnectionCredentials::Available {
            password: Some("手动".into()),
            passphrase: None,
        }
    );
    assert_eq!(
        core.resolve_connection_credentials("host-a", None).unwrap(),
        ConnectionCredentials::Available {
            password: Some("已保存".into()),
            passphrase: None,
        }
    );
    assert!(core
        .resolve_connection_credentials("unknown", None)
        .is_err());
}

#[test]
fn core_connection_credentials_cover_key_and_missing_credential_boundaries() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    let key_host = HostConfig {
        id: "key".into(),
        name: "密钥".into(),
        host: "example.test".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethod::PublicKey {
            key_path: "/tmp/key".into(),
            passphrase_ref: None,
        },
        notes: None,
        group_id: None,
    };
    core.save_host_with_credentials(HostSaveRequest {
        host: key_host,
        password: CredentialIntent::Remove,
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    assert_eq!(
        core.resolve_connection_credentials("key", None).unwrap(),
        ConnectionCredentials::Available {
            password: None,
            passphrase: None,
        }
    );
    assert_eq!(
        core.resolve_connection_credentials("key", Some("口令"))
            .unwrap(),
        ConnectionCredentials::Available {
            password: None,
            passphrase: Some("口令".into()),
        }
    );

    core.save_host(password_host("missing")).unwrap();
    assert_eq!(
        core.resolve_connection_credentials("missing", Some(""))
            .unwrap(),
        ConnectionCredentials::NeedsPassword
    );
}

#[test]
fn connection_credential_resolution_reports_unlock_failure_and_late_removal() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();
    core.save_host_with_credentials(HostSaveRequest {
        host: password_host("host-a"),
        password: CredentialIntent::Set("秘密".into()),
        passphrase: CredentialIntent::Remove,
    })
    .unwrap();
    core.credential_store()
        .set_protection_key(None, Some("保护密钥".into()))
        .unwrap();
    let restarted = PandaCore::new(directory.path()).unwrap();
    assert!(restarted
        .resolve_connection_credentials("host-a", None)
        .is_err());

    // 解锁后预检查可用；随后条目消失时，连接用例必须重新返回待输入状态。
    restarted
        .credential_store()
        .unlock_only("保护密钥")
        .unwrap();
    assert!(matches!(
        restarted
            .resolve_connection_credentials("host-a", None)
            .unwrap(),
        ConnectionCredentials::Available { .. }
    ));
    restarted
        .credential_store()
        .delete("host.host-a.password")
        .unwrap();
    assert_eq!(
        restarted
            .resolve_connection_credentials("host-a", None)
            .unwrap(),
        ConnectionCredentials::NeedsPassword
    );
}
