use panda_core::{AuthMethod, HostConfig, PandaCore};

fn password_host(id: &str, name: &str) -> HostConfig {
    HostConfig {
        id: id.into(),
        name: name.into(),
        host: "example.test".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethod::Password { password_ref: None },
        notes: None,
        group_id: None,
    }
}

#[test]
fn context_constructs_and_persists_hosts_in_its_own_root() {
    let directory = tempfile::tempdir().unwrap();
    let core = PandaCore::new(directory.path()).unwrap();

    core.save_host(password_host("host-a", "甲")).unwrap();

    assert_eq!(
        core.list_hosts().unwrap(),
        vec![password_host("host-a", "甲")]
    );
    assert_eq!(core.config_root(), directory.path());
}

#[test]
fn context_rejects_a_file_as_its_storage_root() {
    let directory = tempfile::tempdir().unwrap();
    let file = directory.path().join("not-a-directory");
    std::fs::write(&file, "not a directory").unwrap();

    assert!(PandaCore::new(&file).is_err());
}

#[test]
fn contexts_with_the_same_host_id_and_old_references_stay_isolated() {
    let first_root = tempfile::tempdir().unwrap();
    let second_root = tempfile::tempdir().unwrap();
    let first = PandaCore::new(first_root.path()).unwrap();
    let second = PandaCore::new(second_root.path()).unwrap();

    first
        .save_host(password_host("same-id", "第一上下文"))
        .unwrap();
    second
        .save_host(password_host("same-id", "第二上下文"))
        .unwrap();

    // 模拟 FFI 默认上下文被替换后，存活操作仍持有它创建时的核心引用。
    let old_operation_context = std::sync::Arc::new(first);
    let replacement_context = std::sync::Arc::new(second);
    old_operation_context
        .save_host(password_host("old-operation", "旧操作"))
        .unwrap();

    assert_eq!(
        old_operation_context.list_hosts().unwrap(),
        vec![
            password_host("same-id", "第一上下文"),
            password_host("old-operation", "旧操作"),
        ]
    );
    assert_eq!(
        replacement_context.list_hosts().unwrap(),
        vec![password_host("same-id", "第二上下文")]
    );
}
