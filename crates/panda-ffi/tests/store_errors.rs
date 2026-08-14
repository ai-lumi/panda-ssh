//! Store 错误路径：损坏的 TOML、非法的 known_hosts、写入失败等场景。
//!
//! 该文件运行在独立进程里，避免污染其它集成测试的全局 `STORES`。

use panda_ffi::{
    delete_host, host_key_status, init_store, list_groups, list_hosts, move_group, save_group,
    save_host, AuthMethodEnum, GroupRecord, HostConfigRecord, PandaError,
};
use std::io::Write;
use uuid::Uuid;

fn fresh_dir() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("panda-ffi-store-errors-{}", Uuid::new_v4()))
}

#[test]
fn store_errors_return_core_error() {
    let dir = fresh_dir();
    std::fs::create_dir_all(&dir).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();

    // 1. 损坏 hosts.toml：让 list_hosts 的解析失败。
    let hosts_path = dir.join("hosts.toml");
    {
        let mut f = std::fs::File::create(&hosts_path).unwrap();
        f.write_all(b"[[host]]\nport = \"not-a-number\"\n").unwrap();
    }
    assert!(matches!(list_hosts(), Err(PandaError::Core(_))));

    // 2. 损坏 groups.toml：让 list_groups 的解析失败。
    let groups_path = dir.join("groups.toml");
    {
        let mut f = std::fs::File::create(&groups_path).unwrap();
        f.write_all(b"[[group]]\nparent_id = 123\n").unwrap();
    }
    assert!(matches!(list_groups(), Err(PandaError::Core(_))));

    // 3. 损坏 known_hosts：让 host_key_status 解析失败。
    let kh_path = dir.join("known_hosts");
    {
        let mut f = std::fs::File::create(&kh_path).unwrap();
        f.write_all(&[0xff, 0xfe]).unwrap();
    }
    assert!(matches!(
        host_key_status("example.com".into(), 22),
        Err(PandaError::Core(_))
    ));

    // 4. 让 hosts.toml 成为目录，导致 save_host 写入失败。
    std::fs::remove_file(&hosts_path).unwrap();
    std::fs::create_dir(&hosts_path).unwrap();
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
    std::fs::remove_dir_all(&hosts_path).unwrap();

    // 5. 先保存一个有效 host，再把 hosts.toml 设为目录，让 delete_host 写入失败。
    save_host(HostConfigRecord {
        id: "to-delete".into(),
        name: "n".into(),
        host: "h".into(),
        port: 22,
        username: "u".into(),
        auth: AuthMethodEnum::Password { password_ref: None },
        notes: None,
        group_id: None,
    })
    .unwrap();
    std::fs::remove_file(&hosts_path).unwrap();
    std::fs::create_dir(&hosts_path).unwrap();
    assert!(matches!(
        delete_host("to-delete".into()),
        Err(PandaError::Core(_))
    ));
    std::fs::remove_dir_all(&hosts_path).unwrap();

    // 6. 让 groups.toml 成为目录，导致 save_group 写入失败。
    std::fs::remove_file(&groups_path).ok();
    std::fs::create_dir(&groups_path).unwrap();
    assert!(matches!(
        save_group(GroupRecord {
            id: String::new(),
            name: "g".into(),
            parent_id: None,
        }),
        Err(PandaError::Core(_))
    ));
    std::fs::remove_dir_all(&groups_path).unwrap();

    // 7. move_group 形成环报错。
    save_group(GroupRecord {
        id: "g1".into(),
        name: "G1".into(),
        parent_id: None,
    })
    .unwrap();
    save_group(GroupRecord {
        id: "g2".into(),
        name: "G2".into(),
        parent_id: Some("g1".into()),
    })
    .unwrap();
    assert!(matches!(
        move_group("g1".into(), Some("g2".into())),
        Err(PandaError::Core(_))
    ));

    // 8. 让 groups.toml 成为目录，导致 move_group 写入失败。
    std::fs::remove_file(&groups_path).ok();
    std::fs::create_dir(&groups_path).unwrap();
    assert!(matches!(
        move_group("g2".into(), None),
        Err(PandaError::Core(_))
    ));

    let _ = std::fs::remove_dir_all(&dir);
}
