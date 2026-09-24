//! 服务器分组模型与 TOML 持久化(groups.toml)。
//!
//! 分组以扁平列表存储,`parent_id` 指向关系隐式构成任意层级树;
//! 与 `hosts.toml` 同目录共存,写入原子完成(temp + rename)。

use std::collections::HashSet;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::config::{write_atomic, ConfigStore};
use crate::Error;

/// 树展开的防御性深度上限:异常数据(环、超长链)不会导致无限递归。
pub const MAX_GROUP_DEPTH: usize = 32;

/// 一个服务器分组;`parent_id` 为 `None` 表示根级分组。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub parent_id: Option<String>,
}

impl Group {
    /// 以随机 UUID 创建分组。
    pub fn new(name: impl Into<String>, parent_id: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            parent_id,
        }
    }
}

/// 分组存储后端抽象,与 `ConfigStore` 同风格。
pub trait GroupStore {
    fn list(&self) -> Result<Vec<Group>, Error>;
    fn get(&self, id: &str) -> Result<Option<Group>, Error>;
    fn upsert(&self, group: Group) -> Result<(), Error>;
    /// 仅删除该条记录;级联删除子分组与主机归属见 `delete_group_cascade`。
    fn delete(&self, id: &str) -> Result<(), Error>;
}

/// groups.toml 的磁盘布局。
#[derive(Debug, Default, Serialize, Deserialize)]
struct GroupsFile {
    #[serde(default, rename = "group")]
    groups: Vec<Group>,
}

/// 将全部分组存于单个 TOML 文件;路径由调用方注入,写入原子完成。
pub struct TomlGroupStore {
    path: PathBuf,
    /// 内存缓存，避免同一实例内重复解析 TOML。
    cache: std::sync::Mutex<Option<Vec<Group>>>,
}

impl TomlGroupStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            cache: std::sync::Mutex::new(None),
        }
    }

    fn read(&self) -> Result<Vec<Group>, Error> {
        {
            let guard = self.cache.lock().unwrap();
            if let Some(ref cached) = *guard {
                return Ok(cached.clone());
            }
        }
        let groups = match std::fs::read_to_string(&self.path) {
            Ok(text) => {
                let file: GroupsFile = toml::from_str(&text)?;
                file.groups
            }
            // 文件不存在 = 尚无分组
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        *self.cache.lock().unwrap() = Some(groups.clone());
        Ok(groups)
    }

    fn write(&self, groups: &[Group]) -> Result<(), Error> {
        let file = GroupsFile {
            groups: groups.to_vec(),
        };
        let text = toml::to_string_pretty(&file)?;
        write_atomic(&self.path, text.as_bytes())?;
        *self.cache.lock().unwrap() = Some(groups.to_vec());
        Ok(())
    }
}

impl GroupStore for TomlGroupStore {
    fn list(&self) -> Result<Vec<Group>, Error> {
        self.read()
    }

    fn get(&self, id: &str) -> Result<Option<Group>, Error> {
        Ok(self.read()?.into_iter().find(|g| g.id == id))
    }

    fn upsert(&self, group: Group) -> Result<(), Error> {
        let mut groups = self.read()?;
        match groups.iter_mut().find(|g| g.id == group.id) {
            Some(existing) => *existing = group,
            None => groups.push(group),
        }
        self.write(&groups)
    }

    fn delete(&self, id: &str) -> Result<(), Error> {
        let mut groups = self.read()?;
        groups.retain(|g| g.id != id);
        self.write(&groups)
    }
}

// ---------------------------------------------------------------------------
// 树展开(纯函数,UI 与级联删除共用)
// ---------------------------------------------------------------------------

/// 根级分组 id:`parent_id` 为空,或指向不存在的分组(悬空引用降级为根级)。
pub fn roots_of(groups: &[Group]) -> Vec<String> {
    groups
        .iter()
        .filter(|g| match &g.parent_id {
            None => true,
            Some(p) => !groups.iter().any(|other| other.id == *p),
        })
        .map(|g| g.id.clone())
        .collect()
}

/// `parent_id` 的直接子分组 id。
pub fn children_of(groups: &[Group], parent_id: &str) -> Vec<String> {
    groups
        .iter()
        .filter(|g| g.parent_id.as_deref() == Some(parent_id))
        .map(|g| g.id.clone())
        .collect()
}

/// 分组及其全部后代 id(显式栈遍历,深度上限 `MAX_GROUP_DEPTH`,visited 防环)。
pub fn descendant_ids(groups: &[Group], id: &str) -> Vec<String> {
    if !groups.iter().any(|g| g.id == id) {
        return Vec::new();
    }
    let mut result = Vec::new();
    let mut visited = HashSet::new();
    let mut stack = vec![(id.to_string(), 0usize)];
    while let Some((current, depth)) = stack.pop() {
        if depth >= MAX_GROUP_DEPTH || !visited.insert(current.clone()) {
            continue;
        }
        result.push(current.clone());
        for child in children_of(groups, &current) {
            if !visited.contains(&child) {
                stack.push((child, depth + 1));
            }
        }
    }
    result
}

/// 删除分组:其下(含子分组)主机的 `group_id` 置空,分组与子分组一并删除,
/// 主机数据完整保留。先清主机引用再删分组记录,任一步失败留下的悬空引用
/// 在读取侧按根级降级,不会丢主机。
pub fn delete_group_cascade(
    groups: &impl GroupStore,
    hosts: &impl ConfigStore,
    id: &str,
) -> Result<(), Error> {
    let doomed: HashSet<String> = descendant_ids(&groups.list()?, id).into_iter().collect();
    for mut host in hosts.list()? {
        if host.group_id.as_ref().is_some_and(|g| doomed.contains(g)) {
            host.group_id = None;
            hosts.upsert(host)?;
        }
    }
    for gid in &doomed {
        groups.delete(gid)?;
    }
    Ok(())
}

/// 变更分组父级(`None` = 移到根级)。父级必须存在,且不允许移入自身或
/// 后代分组(防环);被移分组的子分组随父级整体移动。
pub fn move_group(
    groups: &impl GroupStore,
    id: &str,
    new_parent: Option<&str>,
) -> Result<(), Error> {
    let all = groups.list()?;
    let mut group = all
        .iter()
        .find(|g| g.id == id)
        .cloned()
        .ok_or_else(|| Error::Other(format!("no group with id {id}")))?;
    if let Some(parent) = new_parent {
        if !all.iter().any(|g| g.id == parent) {
            return Err(Error::Other(format!("no group with id {parent}")));
        }
        if parent == id || descendant_ids(&all, id).iter().any(|d| d == parent) {
            return Err(Error::Other(format!(
                "moving group {id} under {parent} would create a cycle"
            )));
        }
    }
    group.parent_id = new_parent.map(str::to_string);
    groups.upsert(group)
}

/// 返回分组的完整路径,格式为 "根 / 子 / 孙"。
///
/// - 未知或空 id 返回 "根级"。
/// - 使用 visited 集合防御环。
/// - 最大深度 = `MAX_GROUP_DEPTH`。
pub fn group_path(groups: &[Group], id: &str) -> String {
    if id.is_empty() {
        return "根级".into();
    }
    // 找到目标分组
    let group = match groups.iter().find(|g| g.id == id) {
        Some(g) => g,
        None => return "根级".into(),
    };
    // 从当前分组向上收集路径
    let mut path_parts: Vec<&str> = vec![&group.name];
    let mut visited = HashSet::new();
    visited.insert(id.to_string());
    let mut current_parent = &group.parent_id;
    let mut depth = 0usize;
    while let Some(ref pid) = *current_parent {
        if depth >= MAX_GROUP_DEPTH || !visited.insert(pid.clone()) {
            break;
        }
        match groups.iter().find(|g| &g.id == pid) {
            Some(parent) => {
                path_parts.push(&parent.name);
                current_parent = &parent.parent_id;
                depth += 1;
            }
            None => break,
        }
    }
    // 反转:从根到叶
    path_parts.reverse();
    path_parts.join(" / ")
}

/// 侧边栏树节点:可以是分组或主机。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarNodeRecord {
    /// 节点 id:"group-xxx" 或 "host-xxx"
    pub id: String,
    /// 是否为分组
    pub is_group: bool,
    /// 显示名称
    pub name: String,
    /// 主机配置(仅主机节点)
    pub host: Option<crate::config::HostConfig>,
    /// 分组配置(仅分组节点)
    pub group: Option<Group>,
    /// 子节点列表。`None` 表示叶子节点(空分组)。
    pub children: Option<Vec<SidebarNodeRecord>>,
}

/// 从扁平的主机和分组列表构建侧边栏树。
///
/// 规则:
/// - 根级分组在前(按存储顺序),根级主机在后
/// - 分组内:子分组在前,成员主机在后
/// - 孤儿主机(group_id 指向不存在的分组)降级到根级
/// - 空分组 → children: None
pub fn sidebar_tree(
    hosts: &[crate::config::HostConfig],
    groups: &[Group],
) -> Vec<SidebarNodeRecord> {
    use std::collections::HashSet;

    let group_ids: HashSet<&str> = groups.iter().map(|g| g.id.as_str()).collect();

    // 按分组 id 收集主机
    let mut hosts_by_group: std::collections::BTreeMap<
        Option<&str>,
        Vec<&crate::config::HostConfig>,
    > = std::collections::BTreeMap::new();
    for host in hosts {
        let key = host
            .group_id
            .as_deref()
            .filter(|gid| group_ids.contains(gid));
        hosts_by_group.entry(key).or_default().push(host);
    }

    // 递归构建分组节点
    fn build_group_node(
        group: &Group,
        groups: &[Group],
        hosts_by_group: &std::collections::BTreeMap<Option<&str>, Vec<&crate::config::HostConfig>>,
    ) -> SidebarNodeRecord {
        let subgroups = children_of(groups, &group.id);
        let member_hosts = hosts_by_group.get(&Some(group.id.as_str()));

        let mut children: Vec<SidebarNodeRecord> = Vec::new();

        // 子分组在前
        for sg_id in &subgroups {
            if let Some(sg) = groups.iter().find(|g| &g.id == sg_id) {
                children.push(build_group_node(sg, groups, hosts_by_group));
            }
        }

        // 成员主机在后
        if let Some(hosts) = member_hosts {
            for h in hosts {
                children.push(SidebarNodeRecord {
                    id: format!("host-{}", h.id),
                    is_group: false,
                    name: h.name.clone(),
                    host: Some((*h).clone()),
                    group: None,
                    children: None,
                });
            }
        }

        SidebarNodeRecord {
            id: format!("group-{}", group.id),
            is_group: true,
            name: group.name.clone(),
            host: None,
            group: Some(group.clone()),
            children: if children.is_empty() {
                None
            } else {
                Some(children)
            },
        }
    }

    let mut result: Vec<SidebarNodeRecord> = Vec::new();

    // 根级分组在前
    for root_id in roots_of(groups) {
        if let Some(g) = groups.iter().find(|g| g.id == root_id) {
            result.push(build_group_node(g, groups, &hosts_by_group));
        }
    }

    // 根级主机在后(包括无 group_id 的和孤儿主机)
    if let Some(root_hosts) = hosts_by_group.get(&None) {
        for h in root_hosts {
            result.push(SidebarNodeRecord {
                id: format!("host-{}", h.id),
                is_group: false,
                name: h.name.clone(),
                host: Some((*h).clone()),
                group: None,
                children: None,
            });
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{AuthMethod, HostConfig, TomlConfigStore};

    fn group(id: &str, name: &str, parent: Option<&str>) -> Group {
        Group {
            id: id.into(),
            name: name.into(),
            parent_id: parent.map(str::to_string),
        }
    }

    // --- 1.1 Group 增删改 + 嵌套序列化 round-trip ---

    #[test]
    fn group_toml_round_trip_with_parent() {
        let g = group("g1", "华东", Some("g0"));
        let text = toml::to_string_pretty(&g).unwrap();
        let back: Group = toml::from_str(&text).unwrap();
        assert_eq!(g, back);
    }

    #[test]
    fn group_toml_round_trip_root() {
        let g = group("g0", "生产环境", None);
        let text = toml::to_string_pretty(&g).unwrap();
        let back: Group = toml::from_str(&text).unwrap();
        assert_eq!(g, back);
    }

    #[test]
    fn group_toml_missing_parent_id_defaults_to_none() {
        let back: Group = toml::from_str("id = \"g1\"\nname = \"x\"").unwrap();
        assert_eq!(back.parent_id, None);
    }

    #[test]
    fn store_upsert_list_delete_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("groups.toml");
        let store = TomlGroupStore::new(path.clone());

        assert!(store.list().unwrap().is_empty());
        assert!(store.get("nope").unwrap().is_none());

        let root = group("g0", "生产环境", None);
        let child = group("g1", "华东", Some("g0"));
        store.upsert(root.clone()).unwrap();
        store.upsert(child.clone()).unwrap();

        let listed = store.list().unwrap();
        assert_eq!(listed, vec![root.clone(), child.clone()]);
        assert_eq!(store.get("g1").unwrap(), Some(child.clone()));

        // 同 id upsert 为替换语义(重命名)
        let renamed = group("g0", "生产", None);
        store.upsert(renamed.clone()).unwrap();
        assert_eq!(store.get("g0").unwrap(), Some(renamed));
        assert_eq!(store.list().unwrap().len(), 2);

        // 重新打开文件:数据已落盘
        let store2 = TomlGroupStore::new(path.clone());
        assert_eq!(store2.list().unwrap().len(), 2);

        store2.delete("g1").unwrap();
        assert_eq!(store2.list().unwrap().len(), 1);
        assert!(store2.get("g1").unwrap().is_none());

        // 删除不存在的 id 是 no-op
        store2.delete("missing").unwrap();
        assert_eq!(store2.list().unwrap().len(), 1);
    }

    #[test]
    fn missing_file_yields_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().join("absent.toml"));
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn invalid_toml_returns_parse_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("groups.toml");
        std::fs::write(&path, "not [valid toml").unwrap();
        let store = TomlGroupStore::new(path);
        assert!(store.list().is_err());
    }

    #[test]
    fn store_operating_on_directory_returns_errors() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().to_path_buf());
        assert!(store.list().is_err());
        assert!(store.get("x").is_err());
        assert!(store.upsert(group("g", "n", None)).is_err());
        assert!(store.delete("x").is_err());
    }

    #[test]
    fn group_new_generates_id() {
        let g = Group::new("开发", None);
        assert_eq!(g.name, "开发");
        assert_eq!(g.parent_id, None);
        assert!(!g.id.is_empty());
    }

    // --- 1.3 树展开 / 悬空降级 / 深度上限 ---

    fn tree() -> Vec<Group> {
        vec![
            group("a", "A", None),
            group("b", "B", Some("a")),
            group("c", "C", Some("b")),
            group("d", "D", Some("c")),
            group("e", "E", None),
        ]
    }

    #[test]
    fn roots_are_parentless_groups() {
        let roots = roots_of(&tree());
        assert_eq!(roots, vec!["a".to_string(), "e".to_string()]);
    }

    #[test]
    fn dangling_parent_degrades_to_root() {
        let groups = vec![group("x", "X", Some("ghost")), group("y", "Y", None)];
        let roots = roots_of(&groups);
        assert_eq!(roots, vec!["x".to_string(), "y".to_string()]);
    }

    #[test]
    fn children_returns_direct_children() {
        assert_eq!(children_of(&tree(), "a"), vec!["b".to_string()]);
        assert_eq!(children_of(&tree(), "d"), Vec::<String>::new());
        assert_eq!(children_of(&tree(), "ghost"), Vec::<String>::new());
    }

    #[test]
    fn descendants_expands_arbitrary_depth() {
        let ids = descendant_ids(&tree(), "a");
        assert_eq!(ids, vec!["a", "b", "c", "d"]);
    }

    #[test]
    fn descendants_of_leaf_and_unknown() {
        assert_eq!(descendant_ids(&tree(), "d"), vec!["d"]);
        assert_eq!(descendant_ids(&tree(), "ghost"), Vec::<String>::new());
    }

    #[test]
    fn descendants_survives_cycles() {
        // 脏数据环:a → b → a;必须终止且各 id 只出现一次
        let groups = vec![
            group("a", "A", Some("b")),
            group("b", "B", Some("a")),
            group("s", "S", Some("a")),
        ];
        let mut ids = descendant_ids(&groups, "a");
        ids.sort();
        assert_eq!(ids, vec!["a", "b", "s"]);
    }

    #[test]
    fn descendants_respects_depth_limit() {
        // 超过 MAX_GROUP_DEPTH 的链:展开在深度上限处截断,不栈溢出
        let mut groups = Vec::new();
        for i in 0..(MAX_GROUP_DEPTH + 10) {
            let parent = if i == 0 {
                None
            } else {
                Some(format!("n{}", i - 1))
            };
            groups.push(group(&format!("n{i}"), "n", parent.as_deref()));
        }
        let ids = descendant_ids(&groups, "n0");
        assert_eq!(ids.len(), MAX_GROUP_DEPTH);
        assert!(ids.contains(&"n0".to_string()));
        assert!(!ids.contains(&format!("n{}", MAX_GROUP_DEPTH)));
    }

    // --- 1.5 删除分组级联:主机回根级,子分组一并删除 ---

    fn host_in_group(id: &str, group_id: Option<&str>) -> HostConfig {
        let mut h = HostConfig::new(
            id,
            "example.com",
            "user",
            AuthMethod::Password { password_ref: None },
        );
        h.id = id.into();
        h.group_id = group_id.map(str::to_string);
        h
    }

    #[test]
    fn delete_group_cascade_moves_hosts_to_root_and_removes_subtree() {
        let dir = tempfile::tempdir().unwrap();
        let groups = TomlGroupStore::new(dir.path().join("groups.toml"));
        let hosts = TomlConfigStore::new(dir.path().join("hosts.toml"));

        groups.upsert(group("a", "A", None)).unwrap();
        groups.upsert(group("b", "B", Some("a"))).unwrap();
        groups.upsert(group("keep", "K", None)).unwrap();
        hosts.upsert(host_in_group("h1", Some("a"))).unwrap();
        hosts.upsert(host_in_group("h2", Some("b"))).unwrap();
        hosts.upsert(host_in_group("h3", Some("keep"))).unwrap();
        hosts.upsert(host_in_group("h4", None)).unwrap();

        delete_group_cascade(&groups, &hosts, "a").unwrap();

        // 分组 a、b 被删除,keep 保留
        let remaining = groups.list().unwrap();
        assert_eq!(remaining, vec![group("keep", "K", None)]);

        // h1/h2 回到根级且数据完整,h3/h4 不受影响
        let listed = hosts.list().unwrap();
        assert_eq!(listed.len(), 4);
        let h1 = hosts.get("h1").unwrap().unwrap();
        assert_eq!(h1.group_id, None);
        assert_eq!(h1.name, "h1");
        assert_eq!(h1.host, "example.com");
        assert_eq!(hosts.get("h2").unwrap().unwrap().group_id, None);
        assert_eq!(
            hosts.get("h3").unwrap().unwrap().group_id.as_deref(),
            Some("keep")
        );
        assert_eq!(hosts.get("h4").unwrap().unwrap().group_id, None);
    }

    #[test]
    fn delete_group_cascade_on_missing_group_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let groups = TomlGroupStore::new(dir.path().join("groups.toml"));
        let hosts = TomlConfigStore::new(dir.path().join("hosts.toml"));
        hosts.upsert(host_in_group("h1", None)).unwrap();

        delete_group_cascade(&groups, &hosts, "ghost").unwrap();
        assert_eq!(hosts.list().unwrap().len(), 1);
    }

    #[test]
    fn delete_group_cascade_clears_dangling_host_reference() {
        // 主机引用了一个不属于被删子树、但本身已不存在的分组:不受影响
        let dir = tempfile::tempdir().unwrap();
        let groups = TomlGroupStore::new(dir.path().join("groups.toml"));
        let hosts = TomlConfigStore::new(dir.path().join("hosts.toml"));
        groups.upsert(group("a", "A", None)).unwrap();
        hosts
            .upsert(host_in_group("h1", Some("other-ghost")))
            .unwrap();

        delete_group_cascade(&groups, &hosts, "a").unwrap();
        assert_eq!(
            hosts.get("h1").unwrap().unwrap().group_id.as_deref(),
            Some("other-ghost")
        );
    }

    // --- move_group:换父级 + 防环 ---

    #[test]
    fn move_group_reparents_subtree_root() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().join("groups.toml"));
        for g in tree() {
            store.upsert(g).unwrap();
        }

        move_group(&store, "b", Some("e")).unwrap();
        assert_eq!(
            store.get("b").unwrap().unwrap().parent_id.as_deref(),
            Some("e")
        );
        // 子分组随父级整体移动(b 的后代关系不变)
        assert_eq!(
            descendant_ids(&store.list().unwrap(), "e"),
            vec!["e", "b", "c", "d"]
        );
    }

    #[test]
    fn move_group_to_root() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().join("groups.toml"));
        for g in tree() {
            store.upsert(g).unwrap();
        }
        move_group(&store, "b", None).unwrap();
        assert_eq!(store.get("b").unwrap().unwrap().parent_id, None);
    }

    #[test]
    fn move_group_rejects_cycle_into_self_or_descendant() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().join("groups.toml"));
        for g in tree() {
            store.upsert(g).unwrap();
        }
        assert!(move_group(&store, "a", Some("a")).is_err());
        assert!(move_group(&store, "a", Some("c")).is_err());
        // 失败后原结构不变
        assert_eq!(store.get("a").unwrap().unwrap().parent_id, None);
    }

    #[test]
    fn move_group_rejects_unknown_parent_or_unknown_group() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlGroupStore::new(dir.path().join("groups.toml"));
        store.upsert(group("a", "A", None)).unwrap();
        assert!(move_group(&store, "a", Some("ghost")).is_err());
        assert!(move_group(&store, "ghost", None).is_err());
    }

    // --- 1.7 HostConfig.group_id 兼容旧文件 ---

    #[test]
    fn host_config_without_group_id_defaults_to_root() {
        // 旧版 hosts.toml 条目没有 group_id 字段
        let text = r#"
id = "11111111-2222-3333-4444-555555555555"
name = "box"
host = "example.com"
port = 22
username = "panda"

[auth]
type = "password"
"#;
        let back: HostConfig = toml::from_str(text).unwrap();
        assert_eq!(back.group_id, None);
    }

    #[test]
    fn host_config_group_id_round_trip() {
        let mut h = HostConfig::new(
            "box",
            "example.com",
            "panda",
            AuthMethod::Password { password_ref: None },
        );
        h.group_id = Some("g1".into());
        let text = toml::to_string_pretty(&h).unwrap();
        let back: HostConfig = toml::from_str(&text).unwrap();
        assert_eq!(h, back);
        assert_eq!(back.group_id.as_deref(), Some("g1"));
    }

    // --- 空列表边界 ---

    #[test]
    fn roots_of_empty_list_returns_empty() {
        assert_eq!(roots_of(&[]), Vec::<String>::new());
    }

    #[test]
    fn children_of_empty_list_returns_empty() {
        assert_eq!(children_of(&[], "any"), Vec::<String>::new());
    }

    #[test]
    fn descendant_ids_of_empty_list_returns_empty() {
        assert_eq!(descendant_ids(&[], "any"), Vec::<String>::new());
    }

    #[test]
    fn delete_group_cascade_on_empty_stores_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let groups = TomlGroupStore::new(dir.path().join("groups.toml"));
        let hosts = TomlConfigStore::new(dir.path().join("hosts.toml"));
        delete_group_cascade(&groups, &hosts, "ghost").unwrap();
        assert!(groups.list().unwrap().is_empty());
        assert!(hosts.list().unwrap().is_empty());
    }

    // --- group_path ---

    #[test]
    fn group_path_multi_level() {
        let groups = vec![
            group("a", "根组", None),
            group("b", "子组", Some("a")),
            group("c", "孙组", Some("b")),
        ];
        assert_eq!(group_path(&groups, "c"), "根组 / 子组 / 孙组");
    }

    #[test]
    fn group_path_single_root() {
        let groups = vec![group("a", "根组", None)];
        assert_eq!(group_path(&groups, "a"), "根组");
    }

    #[test]
    fn group_path_unknown_id_returns_root_level() {
        let groups = vec![group("a", "根组", None)];
        assert_eq!(group_path(&groups, "ghost"), "根级");
    }

    #[test]
    fn group_path_empty_id_returns_root_level() {
        let groups = vec![group("a", "根组", None)];
        assert_eq!(group_path(&groups, ""), "根级");
    }

    #[test]
    fn group_path_cycle_defense() {
        // 脏数据环:a → b → a
        let groups = vec![group("a", "A", Some("b")), group("b", "B", Some("a"))];
        // 不应无限循环,结果应包含两个名称
        let path = group_path(&groups, "b");
        assert!(path.contains("A"));
        assert!(path.contains("B"));

        // 悬空 parent_id:父组不存在
        let dangling = vec![group("x", "X", Some("nonexistent"))];
        assert_eq!(group_path(&dangling, "x"), "X");
    }

    #[test]
    fn group_path_empty_list_returns_root_level() {
        assert_eq!(group_path(&[], "any"), "根级");
    }

    // --- sidebar_tree ---

    fn sidebar_host(id: &str, name: &str, group_id: Option<&str>) -> HostConfig {
        let mut h = HostConfig::new(
            name,
            "example.com",
            "user",
            AuthMethod::Password { password_ref: None },
        );
        h.id = id.into();
        h.group_id = group_id.map(str::to_string);
        h
    }

    #[test]
    fn sidebar_tree_standard_with_groups_and_hosts() {
        let groups = vec![group("g1", "生产", None), group("g2", "华东", Some("g1"))];
        let hosts = vec![
            sidebar_host("h1", "web", Some("g2")),
            sidebar_host("h2", "db", Some("g1")),
            sidebar_host("h3", "root-host", None),
        ];
        let tree = sidebar_tree(&hosts, &groups);
        // 根级: g1(生产) 在前, h3(root-host) 在后
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].id, "group-g1");
        assert!(tree[0].is_group);
        assert_eq!(tree[1].id, "host-h3");
        assert!(!tree[1].is_group);
        // g1 的子节点: g2(华东) 在前, h2(db) 在后
        let g1_children = tree[0].children.as_ref().unwrap();
        assert_eq!(g1_children.len(), 2);
        assert_eq!(g1_children[0].id, "group-g2");
        assert_eq!(g1_children[1].id, "host-h2");
        // g2 的子节点: h1(web)
        let g2_children = g1_children[0].children.as_ref().unwrap();
        assert_eq!(g2_children.len(), 1);
        assert_eq!(g2_children[0].id, "host-h1");
    }

    #[test]
    fn sidebar_tree_orphan_host_demoted_to_root() {
        let groups = vec![group("g1", "生产", None)];
        let hosts = vec![
            sidebar_host("h1", "orphan", Some("ghost")),
            sidebar_host("h2", "normal", Some("g1")),
        ];
        let tree = sidebar_tree(&hosts, &groups);
        // g1 在前, orphan host 降级到根级在后
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].id, "group-g1");
        assert_eq!(tree[1].id, "host-h1");
        assert_eq!(tree[1].name, "orphan");
    }

    #[test]
    fn sidebar_tree_empty_input_returns_empty() {
        assert!(sidebar_tree(&[], &[]).is_empty());
    }

    #[test]
    fn sidebar_tree_node_id_prefix_encoding() {
        let groups = vec![group("g1", "组", None)];
        let hosts = vec![sidebar_host("h1", "主机", Some("g1"))];
        let tree = sidebar_tree(&hosts, &groups);
        assert!(tree[0].id.starts_with("group-"));
        let children = tree[0].children.as_ref().unwrap();
        assert!(children[0].id.starts_with("host-"));
    }

    #[test]
    fn sidebar_tree_empty_group_has_none_children() {
        let groups = vec![group("g1", "空组", None)];
        let tree = sidebar_tree(&[], &groups);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].children, None);
    }
}
