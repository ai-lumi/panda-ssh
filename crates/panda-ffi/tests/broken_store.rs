//! Store 指向损坏路径（`hosts.toml` 是目录）时，所有依赖 store 的导出函数
//! 必须返回 `PandaError::Core`。
//!
//! 该文件运行在独立进程里，确保 `init_store` 首次调用能指向这个损坏路径。

use panda_ffi::{delete_host, init_store, list_hosts, save_host, sftp_list, test_connection};
use panda_ffi::{AuthMethodEnum, HostConfigRecord, PandaError};
use uuid::Uuid;

#[test]
fn broken_store_returns_core_errors() {
    let dir = std::env::temp_dir().join(format!("panda-ffi-broken-store-{}", Uuid::new_v4()));
    // hosts.toml 是一个目录，读取/写入都会失败。
    std::fs::create_dir_all(dir.join("hosts.toml")).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();

    assert!(matches!(list_hosts(), Err(PandaError::Core(_))));
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
        Err(PandaError::Core(_))
    ));
    assert!(matches!(delete_host("x".into()), Err(PandaError::Core(_))));
    assert!(matches!(
        test_connection("x".into(), None, None, true),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        sftp_list("x".into(), "/".into(), None, None, true),
        Err(PandaError::Core(_))
    ));

    let _ = std::fs::remove_dir_all(&dir);
}
