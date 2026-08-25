//! 未初始化 store 的行为：在所有调用 `init_store` 之前，导出函数必须返回
//! `PandaError::NotInitialized`；`init_store` 指向非法路径时必须报错。
//!
//! 该文件运行在独立进程里（与其它集成测试分开），确保全局 `STORES` 未被
//! 其它测试初始化。

use panda_ffi::{accept_unknown_host_key, host_key_status};
use panda_ffi::{
    credential_protection_enabled, delete_credential, delete_host, init_store, list_hosts,
    read_credential, save_credential, save_host, set_credential_protection_key,
    sftp_check_download_conflict, sftp_check_upload_conflict, sftp_list, shell_open,
    test_connection,
};
use panda_ffi::{delete_group, list_groups, move_group, save_group};
use panda_ffi::{AuthMethodEnum, GroupRecord, HostConfigRecord, PandaError};
use uuid::Uuid;

#[test]
fn store_not_initialized_returns_not_initialized() {
    assert!(matches!(list_hosts(), Err(PandaError::NotInitialized)));
    assert!(matches!(
        test_connection("x".into(), None, None, true),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        sftp_list("x".into(), "/".into(), None, None, true),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        save_host(HostConfigRecord {
            id: String::new(),
            name: "n".into(),
            host: "h".into(),
            port: 22,
            username: "u".into(),
            auth: AuthMethodEnum::Password { password_ref: None },
            notes: None,
            group_id: None,
        }),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        delete_host("x".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        save_credential("ref".into(), "secret".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        read_credential("ref".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        delete_credential("ref".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        set_credential_protection_key(None, Some("key".into())),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        credential_protection_enabled(),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(list_groups(), Err(PandaError::NotInitialized)));
    assert!(matches!(
        save_group(GroupRecord {
            id: String::new(),
            name: "g".into(),
            parent_id: None,
        }),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        delete_group("x".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        move_group("x".into(), None),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        host_key_status("h".into(), 22),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        accept_unknown_host_key("h".into(), 22, "ssh-ed25519 AAAA".into()),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        sftp_check_upload_conflict(
            "x".into(),
            "/tmp/a".into(),
            "/remote/a".into(),
            None,
            None,
            true
        ),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        sftp_check_download_conflict(
            "x".into(),
            "/remote/a".into(),
            "/tmp/a".into(),
            None,
            None,
            true
        ),
        Err(PandaError::NotInitialized)
    ));
    assert!(matches!(
        shell_open("x".into(), None, None, true),
        Err(PandaError::NotInitialized)
    ));
}

#[test]
fn init_store_with_bad_path_returns_error() {
    let parent = std::env::temp_dir().join(format!("panda-ffi-bad-path-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&parent).unwrap();
    let blocker = parent.join("blocker");
    std::fs::write(&blocker, b"x").unwrap();

    let bad = blocker.join("sub");
    assert!(init_store(bad.to_string_lossy().into_owned()).is_err());

    let _ = std::fs::remove_dir_all(&parent);
}
