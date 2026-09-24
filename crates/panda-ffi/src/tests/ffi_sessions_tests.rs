use super::*;
use crate::test_support::global_test_lock;
use std::time::{Duration, UNIX_EPOCH};

#[test]
fn remote_file_records_preserve_metadata_and_handle_pre_epoch_time() {
    let records = remote_file_records(vec![
        panda_core::RemoteFile {
            name: "dir".into(),
            path: "/dir".into(),
            is_dir: true,
            size: 0,
            modified: Some(UNIX_EPOCH + Duration::from_secs(9)),
        },
        panda_core::RemoteFile {
            name: "old".into(),
            path: "/old".into(),
            is_dir: false,
            size: 3,
            modified: Some(UNIX_EPOCH - Duration::from_secs(1)),
        },
    ]);
    assert_eq!(records[0].modified, Some(9));
    assert!(records[0].is_dir);
    assert_eq!(records[1].modified, None);
    assert_eq!(records[1].size, 3);
}

#[test]
fn unknown_sftp_handle_is_rejected_without_connection() {
    let _test_guard = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    assert!(matches!(
        sftp_session_list(u64::MAX, "/".into()),
        Err(PandaError::UnknownSftpHandle(u64::MAX))
    ));
}

#[test]
fn every_session_handle_operation_rejects_an_unknown_handle_without_network_io() {
    let _test_guard = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    let handle = u64::MAX;

    assert!(matches!(
        sftp_session_check_upload_conflict(handle, "/local".into(), "/remote".into()),
        Err(PandaError::UnknownSftpHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        sftp_session_check_download_conflict(handle, "/remote".into(), "/local".into()),
        Err(PandaError::UnknownSftpHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        sftp_session_remove_file(handle, "/remote".into()),
        Err(PandaError::UnknownSftpHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        sftp_session_remove_dir(handle, "/remote".into()),
        Err(PandaError::UnknownSftpHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        sftp_session_create_dir(handle, "/remote".into()),
        Err(PandaError::UnknownSftpHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        shell_write(handle, b"echo test".to_vec()),
        Err(PandaError::UnknownShellHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        shell_read(handle, 128),
        Err(PandaError::UnknownShellHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        shell_resize(handle, 80, 24),
        Err(PandaError::UnknownShellHandle(actual)) if actual == handle
    ));
    assert!(matches!(
        shell_close(handle),
        Err(PandaError::UnknownShellHandle(actual)) if actual == handle
    ));
}

#[test]
fn close_sftp_session_rejects_never_issued_handle() {
    let _test_guard = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    assert!(matches!(
        sftp_session_close(u64::MAX),
        Err(PandaError::UnknownSftpHandle(u64::MAX))
    ));
}

#[test]
fn shell_close_rejects_handle_zero_as_unknown() {
    let _test_guard = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    assert!(matches!(
        shell_close(0),
        Err(PandaError::UnknownShellHandle(0))
    ));
}

#[test]
fn standalone_operations_reject_unknown_hosts_before_starting_a_connection() {
    let _test_guard = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    let unknown = "ffi-sessions-unknown-host".to_string();
    let password = Some("unused".to_string());
    let passphrase = Some("unused".to_string());
    let expected = |result: Result<(), PandaError>| {
        assert!(matches!(result, Err(PandaError::UnknownHost(ref id)) if id == &unknown));
    };

    expected(sftp_upload(
        unknown.clone(),
        "/local".into(),
        "/remote".into(),
        password.clone(),
        passphrase.clone(),
        false,
    ));
    expected(sftp_download(
        unknown.clone(),
        "/remote".into(),
        "/local".into(),
        password.clone(),
        passphrase.clone(),
        false,
    ));
    expected(sftp_remove_file(
        unknown.clone(),
        "/remote".into(),
        password.clone(),
        passphrase.clone(),
        false,
    ));
    expected(sftp_remove_dir(
        unknown.clone(),
        "/remote".into(),
        password.clone(),
        passphrase.clone(),
        false,
    ));
    expected(sftp_create_dir(
        unknown.clone(),
        "/remote".into(),
        password.clone(),
        passphrase.clone(),
        false,
    ));
    assert!(matches!(
        sftp_session_open(
            unknown.clone(),
            password.clone(),
            passphrase.clone(),
            false,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        shell_open(unknown.clone(), password.clone(), passphrase.clone(), false),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        test_connection(unknown.clone(), password.clone(), passphrase.clone(), false),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        sftp_list(
            unknown.clone(),
            "/".into(),
            password.clone(),
            passphrase.clone(),
            false,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        sftp_check_upload_conflict(
            unknown.clone(),
            "/local".into(),
            "/remote".into(),
            password.clone(),
            passphrase.clone(),
            false,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        sftp_check_download_conflict(
            unknown.clone(),
            "/remote".into(),
            "/local".into(),
            password.clone(),
            passphrase.clone(),
            false,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        sftp_home_dir(unknown, password, passphrase, false),
        Err(PandaError::UnknownHost(ref id)) if id == "ffi-sessions-unknown-host"
    ));
}

#[test]
fn session_cancel_with_initialized_store_does_not_panic() {
    let _g = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    session_cancel("nonexistent-session".into());
}

#[test]
fn tracked_open_functions_reject_unknown_hosts() {
    let _g = global_test_lock();
    let dir = tempfile::tempdir().unwrap();
    crate::ffi_store::init_store(dir.path().to_string_lossy().into_owned()).unwrap();
    let unknown = "ffi-tracked-unknown-host".to_string();
    let password = Some("unused".to_string());
    let passphrase = Some("unused".to_string());

    assert!(matches!(
        sftp_session_open_tracked(
            unknown.clone(),
            password.clone(),
            passphrase.clone(),
            false,
            "sid".into(),
            0,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
    assert!(matches!(
        shell_open_tracked(
            unknown.clone(),
            password.clone(),
            passphrase.clone(),
            false,
            "sid".into(),
            0,
        ),
        Err(PandaError::UnknownHost(ref id)) if id == &unknown
    ));
}

#[test]
fn session_is_stale_and_has_active_without_init_store() {
    let _g = global_test_lock();
    crate::ffi_store::reset_store_for_test();
    assert!(session_is_stale("any".into(), 0));
    assert!(!session_has_active("any".into(), 0));
}

#[test]
fn session_cancel_without_init_store_does_not_panic() {
    let _g = global_test_lock();
    crate::ffi_store::reset_store_for_test();
    session_cancel("any-session".into());
}
