//! FFI 分组导出与主机归属的行为测试:分组 CRUD、主机 group_id 读写、
//! 删除分组级联(主机回根级、子分组一并删除)、move_group 换父级与防环。
//!
//! 独立测试二进制 = 独立进程,全局 `STORES` 只在本文件内初始化。

use panda_ffi::{
    delete_group, delete_host, init_store, list_groups, list_hosts, move_group, save_group,
    save_host, AuthMethodEnum, GroupRecord, HostConfigRecord,
};

/// 全部测试共享同一个 store 目录,串行执行避免并发写 groups.toml/hosts.toml。
static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn ensure_store_and_clear() {
    let dir = std::env::temp_dir().join("panda-ffi-groups-store");
    std::fs::create_dir_all(&dir).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();
    for g in list_groups().unwrap() {
        panda_ffi::delete_group(g.id).unwrap();
    }
    for h in list_hosts().unwrap() {
        delete_host(h.id).unwrap();
    }
}

fn group(id: &str, name: &str, parent: Option<&str>) -> GroupRecord {
    GroupRecord {
        id: id.into(),
        name: name.into(),
        parent_id: parent.map(str::to_string),
    }
}

fn host(id: &str, group_id: Option<&str>) -> HostConfigRecord {
    HostConfigRecord {
        id: id.into(),
        name: id.into(),
        host: "example.com".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethodEnum::Password { password_ref: None },
        notes: None,
        group_id: group_id.map(str::to_string),
    }
}

#[test]
fn group_crud_round_trip() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear();
    assert!(list_groups().unwrap().is_empty());

    // 空 id 保存 → 生成新 UUID
    save_group(group("", "生产环境", None)).unwrap();
    let created = list_groups().unwrap();
    assert_eq!(created.len(), 1);
    assert!(!created[0].id.is_empty());
    assert_eq!(created[0].name, "生产环境");
    assert_eq!(created[0].parent_id, None);

    // 子分组 + 重命名(同 id 替换)
    let root_id = created[0].id.clone();
    save_group(group("g-child", "华东", Some(&root_id))).unwrap();
    save_group(group(&root_id, "生产", None)).unwrap();
    let groups = list_groups().unwrap();
    assert_eq!(groups.len(), 2);
    let root = groups.iter().find(|g| g.id == root_id).unwrap();
    assert_eq!(root.name, "生产");
    let child = groups.iter().find(|g| g.id == "g-child").unwrap();
    assert_eq!(child.parent_id.as_deref(), Some(root_id.as_str()));

    // 删除单个分组
    delete_group("g-child".into()).unwrap();
    let groups = list_groups().unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].id, root_id);
}

#[test]
fn host_group_id_round_trip() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear();
    save_group(group("g1", "开发", None)).unwrap();
    save_host(host("h1", Some("g1"))).unwrap();
    save_host(host("h2", None)).unwrap();

    let hosts = list_hosts().unwrap();
    let h1 = hosts.iter().find(|h| h.id == "h1").unwrap();
    assert_eq!(h1.group_id.as_deref(), Some("g1"));
    let h2 = hosts.iter().find(|h| h.id == "h2").unwrap();
    assert_eq!(h2.group_id, None);

    // 更新归属(移动主机)
    save_host(host("h1", None)).unwrap();
    let h1 = list_hosts().unwrap().into_iter().find(|h| h.id == "h1").unwrap();
    assert_eq!(h1.group_id, None);
}

#[test]
fn delete_group_cascades_hosts_to_root_and_removes_subtree() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear();
    save_group(group("a", "A", None)).unwrap();
    save_group(group("b", "B", Some("a"))).unwrap();
    save_group(group("keep", "K", None)).unwrap();
    save_host(host("h1", Some("a"))).unwrap();
    save_host(host("h2", Some("b"))).unwrap();
    save_host(host("h3", Some("keep"))).unwrap();

    delete_group("a".into()).unwrap();

    // 分组 a、b 删除,keep 保留
    let groups = list_groups().unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].id, "keep");

    // 主机全部保留,h1/h2 回根级,h3 归属不变
    let hosts = list_hosts().unwrap();
    assert_eq!(hosts.len(), 3);
    for id in ["h1", "h2"] {
        let h = hosts.iter().find(|h| h.id == id).unwrap();
        assert_eq!(h.group_id, None, "{id} 应回到根级");
        assert_eq!(h.host, "example.com");
    }
    let h3 = hosts.iter().find(|h| h.id == "h3").unwrap();
    assert_eq!(h3.group_id.as_deref(), Some("keep"));
}

#[test]
fn move_group_reparents_and_defends_cycles() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear();
    save_group(group("a", "A", None)).unwrap();
    save_group(group("b", "B", Some("a"))).unwrap();
    save_group(group("e", "E", None)).unwrap();

    // 换父级
    move_group("b".into(), Some("e".into())).unwrap();
    let b = list_groups().unwrap().into_iter().find(|g| g.id == "b").unwrap();
    assert_eq!(b.parent_id.as_deref(), Some("e"));

    // 移回根级
    move_group("b".into(), None).unwrap();
    let b = list_groups().unwrap().into_iter().find(|g| g.id == "b").unwrap();
    assert_eq!(b.parent_id, None);

    // 防环:移入自身 / 后代
    assert!(move_group("a".into(), Some("a".into())).is_err());
    save_group(group("c", "C", Some("a"))).unwrap();
    assert!(move_group("a".into(), Some("c".into())).is_err());

    // 未知分组 / 未知父级
    assert!(move_group("ghost".into(), None).is_err());
    assert!(move_group("a".into(), Some("ghost".into())).is_err());
}

#[test]
fn delete_missing_group_is_noop() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear();
    save_host(host("h1", None)).unwrap();
    delete_group("ghost".into()).unwrap();
    assert_eq!(list_hosts().unwrap().len(), 1);
}
