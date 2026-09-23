use panda_ffi::{
    connection_credentials, init_store, list_hosts, read_credential, save_host_with_credentials,
    AuthMethodEnum, CredentialIntentEnum, HostConfigRecord, ResolvedCredentialEnum,
};

fn host() -> HostConfigRecord {
    HostConfigRecord {
        id: "host-save".into(),
        name: "主机".into(),
        host: "example.test".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethodEnum::Password { password_ref: None },
        notes: None,
        group_id: None,
    }
}

#[test]
fn ffi_complete_host_save_preserves_an_unedited_credential() {
    let directory = tempfile::tempdir().unwrap();
    init_store(directory.path().display().to_string()).unwrap();

    save_host_with_credentials(
        host(),
        CredentialIntentEnum::Set {
            secret: "密码".into(),
        },
        CredentialIntentEnum::Remove,
    )
    .unwrap();
    let saved = save_host_with_credentials(
        HostConfigRecord {
            name: "已编辑".into(),
            ..host()
        },
        CredentialIntentEnum::Preserve,
        CredentialIntentEnum::Remove,
    )
    .unwrap();

    assert_eq!(saved.name, "已编辑");
    let listed = list_hosts().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, saved.id);
    assert_eq!(listed[0].name, saved.name);
    assert_eq!(
        read_credential("host.host-save.password".into())
            .unwrap()
            .as_deref(),
        Some("密码")
    );

    assert!(save_host_with_credentials(
        HostConfigRecord {
            id: String::new(),
            ..host()
        },
        CredentialIntentEnum::Set {
            secret: "密码".into(),
        },
        CredentialIntentEnum::Remove,
    )
    .is_err());
    assert_eq!(list_hosts().unwrap().len(), 1);

    assert!(matches!(
        connection_credentials("host-save".into(), Some("手动".into())).unwrap(),
        ResolvedCredentialEnum::Available { password: Some(password), passphrase: None }
            if password == "手动"
    ));
    assert!(matches!(
        connection_credentials("host-save".into(), None).unwrap(),
        ResolvedCredentialEnum::Available { password: Some(password), passphrase: None }
            if password == "密码"
    ));
    assert!(connection_credentials("missing".into(), None).is_err());
}
