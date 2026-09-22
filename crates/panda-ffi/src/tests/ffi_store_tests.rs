    use super::*;
    use crate::test_support::global_test_lock;
    use crate::test_support::GlobalTestGuard;
    use crate::AuthMethodEnum;
    use std::io::Write;

    /// 合法 `<keytype> <base64>` 格式的测试公钥；指纹计算只解码不校验密钥内容。
    const TEST_KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    /// 在独立临时目录中初始化 store；返回的锁保证串行，tempdir 由调用方持有。
    fn init_test_store() -> (GlobalTestGuard, tempfile::TempDir) {
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        init_store(dir.path().to_string_lossy().into_owned()).unwrap();
        (lock, dir)
    }

    fn password_host(id: &str, name: &str, addr: &str) -> HostConfigRecord {
        HostConfigRecord {
            id: id.into(),
            name: name.into(),
            host: addr.into(),
            port: 22,
            username: "deploy".into(),
            auth: AuthMethodEnum::Password {
                password_ref: Some(format!("host.{id}.password")),
            },
            notes: None,
            group_id: None,
        }
    }

    fn key_host(id: &str, name: &str, passphrase_ref: Option<String>) -> HostConfigRecord {
        HostConfigRecord {
            id: id.into(),
            name: name.into(),
            host: format!("{id}.example.com"),
            port: 22,
            username: "deploy".into(),
            auth: AuthMethodEnum::PublicKey {
                key_path: "/tmp/id_ed25519".into(),
                passphrase_ref,
            },
            notes: None,
            group_id: None,
        }
    }

    fn new_group(name: &str, parent: Option<&str>) -> GroupRecord {
        GroupRecord {
            id: String::new(),
            name: name.into(),
            parent_id: parent.map(str::to_string),
        }
    }

    /// 创建分组并从列表取回带生成 id 的记录（save_group 不返回保存结果）。
    fn create_group(name: &str, parent: Option<&str>) -> GroupRecord {
        save_group(new_group(name, parent)).unwrap();
        list_groups()
            .unwrap()
            .into_iter()
            .find(|g| g.name == name)
            .unwrap()
    }

    #[test]
    fn search_hosts_matches_name_username_group_path_and_empty_query() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        save_host(password_host("db", "数据库", "db.prod.example.com")).unwrap();
        let mut web = password_host("web", "Web", "web.example.com");
        web.group_id = Some(prod.id.clone());
        save_host(web).unwrap();

        // 名称命中
        assert_eq!(search_hosts("数据".into()).unwrap().len(), 1);
        // 用户名命中（两台同名用户）
        assert_eq!(search_hosts("deploy".into()).unwrap().len(), 2);
        // 分组路径命中
        assert_eq!(search_hosts("生产".into()).unwrap().len(), 1);
        // 空查询返回全部
        assert_eq!(search_hosts("".into()).unwrap().len(), 2);
        // 无命中
        assert!(search_hosts("不存在".into()).unwrap().is_empty());
    }

    #[test]
    fn credential_resolve_maps_available_needs_password_and_passphrase() {
        let (_lock, _dir) = init_test_store();

        // 已保存密码 → Available
        save_host(password_host("with-pw", "带密码", "a.example.com")).unwrap();
        save_credential("host.with-pw.password".into(), "secret".into()).unwrap();
        match credential_resolve("with-pw".into()).unwrap() {
            ResolvedCredentialEnum::Available {
                password,
                passphrase,
            } => {
                assert_eq!(password.as_deref(), Some("secret"));
                assert_eq!(passphrase, None);
            }
            other => panic!("期望 Available，实际 {other:?}"),
        }

        // 密码认证但未保存 → NeedsPassword
        save_host(password_host("no-pw", "无密码", "b.example.com")).unwrap();
        assert!(matches!(
            credential_resolve("no-pw".into()).unwrap(),
            ResolvedCredentialEnum::NeedsPassword
        ));

        // 公钥认证带加密私钥但口令未保存 → NeedsPassphrase
        save_host(key_host(
            "locked-key",
            "加密私钥",
            Some("host.locked-key.passphrase".into()),
        ))
        .unwrap();
        assert!(matches!(
            credential_resolve("locked-key".into()).unwrap(),
            ResolvedCredentialEnum::NeedsPassphrase
        ));

        // 公钥认证无加密私钥 → Available(None, None)
        save_host(key_host("plain-key", "明文私钥", None)).unwrap();
        match credential_resolve("plain-key".into()).unwrap() {
            ResolvedCredentialEnum::Available {
                password,
                passphrase,
            } => {
                assert_eq!(password, None);
                assert_eq!(passphrase, None);
            }
            other => panic!("期望 Available，实际 {other:?}"),
        }

        // 未知主机 → 结构化错误
        assert!(credential_resolve("ghost".into()).is_err());
    }

    #[test]
    fn host_key_status_reports_unknown_then_known_after_accept() {
        let (_lock, _dir) = init_test_store();

        assert!(matches!(
            host_key_status("tofu.example.com".into(), 22).unwrap(),
            KnownHostStatusEnum::Unknown
        ));

        accept_unknown_host_key("tofu.example.com".into(), 22, TEST_KEY.into()).unwrap();
        match host_key_status("tofu.example.com".into(), 22).unwrap() {
            KnownHostStatusEnum::Known {
                fingerprint,
                key_type,
            } => {
                assert!(
                    fingerprint.starts_with("SHA256:"),
                    "指纹应为 SHA256 冒号格式"
                );
                assert_eq!(key_type, "ssh-ed25519");
            }
            other => panic!("期望 Known，实际 {other:?}"),
        }

        // 格式非法的密钥被拒绝
        assert!(
            accept_unknown_host_key("tofu.example.com".into(), 22, "not-a-key".into()).is_err()
        );
    }

    #[test]
    fn preconnect_evaluate_maps_every_reachable_action() {
        let (_lock, _dir) = init_test_store();

        // 未知主机：无论凭据如何，先要求 TOFU 确认
        save_host(password_host("tofu-host", "TOFU", "tofu.example.com")).unwrap();
        assert!(matches!(
            preconnect_evaluate("tofu-host".into()).unwrap(),
            PreconnectActionEnum::ConfirmTofu
        ));

        // 密钥已知 + 密码已保存 → Proceed
        accept_unknown_host_key("tofu.example.com".into(), 22, TEST_KEY.into()).unwrap();
        save_credential("host.tofu-host.password".into(), "secret".into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("tofu-host".into()).unwrap(),
            PreconnectActionEnum::Proceed
        ));

        // 密钥已知 + 密码未保存 → AskPassword
        save_host(password_host("ask-pw", "要密码", "ask.example.com")).unwrap();
        accept_unknown_host_key("ask.example.com".into(), 22, TEST_KEY.into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("ask-pw".into()).unwrap(),
            PreconnectActionEnum::AskPassword
        ));

        // 密钥已知 + 加密私钥无口令 → AskPassphrase
        save_host(key_host(
            "ask-pp",
            "要口令",
            Some("host.ask-pp.passphrase".into()),
        ))
        .unwrap();
        accept_unknown_host_key("ask-pp.example.com".into(), 22, TEST_KEY.into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("ask-pp".into()).unwrap(),
            PreconnectActionEnum::AskPassphrase
        ));

        // 未知主机 id → 结构化错误
        assert!(preconnect_evaluate("ghost".into()).is_err());
    }

    #[test]
    fn map_preconnect_action_converts_core_variants_including_key_mismatch() {
        // KeyMismatch 在文件级评估中不可达（KnownHostStatus 无 Mismatch 变体），
        // 但映射必须保持完整，直接对映射函数验证。
        match map_preconnect_action(panda_core::PreconnectAction::KeyMismatch {
            stored_fingerprint: "SHA256:stored".into(),
            presented_fingerprint: "SHA256:presented".into(),
        }) {
            PreconnectActionEnum::KeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
            } => {
                assert_eq!(stored_fingerprint, "SHA256:stored");
                assert_eq!(presented_fingerprint, "SHA256:presented");
            }
            other => panic!("期望 KeyMismatch，实际 {other:?}"),
        }
        assert_eq!(
            map_preconnect_action(panda_core::PreconnectAction::Proceed),
            PreconnectActionEnum::Proceed
        );
        assert_eq!(
            map_preconnect_action(panda_core::PreconnectAction::ConfirmTofu),
            PreconnectActionEnum::ConfirmTofu
        );
        assert!(matches!(
            map_preconnect_action(panda_core::PreconnectAction::AskPassword),
            PreconnectActionEnum::AskPassword
        ));
        assert!(matches!(
            map_preconnect_action(panda_core::PreconnectAction::AskPassphrase),
            PreconnectActionEnum::AskPassphrase
        ));
    }

    #[test]
    fn credential_protection_roundtrip_rewrites_file_with_new_key() {
        let (_lock, _dir) = init_test_store();

        save_credential("host.protected.password".into(), "secret".into()).unwrap();
        assert!(!credential_protection_enabled().unwrap());

        // 明文 → 加密
        set_credential_protection_key(None, Some("key1".into())).unwrap();
        assert!(credential_protection_enabled().unwrap());
        assert_eq!(
            read_credential("host.protected.password".into())
                .unwrap()
                .as_deref(),
            Some("secret")
        );

        // 旧密钥解锁后以新密钥重写
        set_credential_protection_key(Some("key1".into()), Some("key2".into())).unwrap();
        assert_eq!(
            read_credential("host.protected.password".into())
                .unwrap()
                .as_deref(),
            Some("secret")
        );

        // 迁回明文
        set_credential_protection_key(Some("key2".into()), None).unwrap();
        assert!(!credential_protection_enabled().unwrap());
        assert_eq!(
            read_credential("host.protected.password".into())
                .unwrap()
                .as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn group_path_reports_hierarchy_and_unknown_ids() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        assert_eq!(group_path(east.id.clone()).unwrap(), "生产 / 华东");
        assert_eq!(group_path(prod.id.clone()).unwrap(), "生产");
        assert_eq!(group_path("nope".into()).unwrap(), "根级");
        assert_eq!(group_path(String::new()).unwrap(), "根级");
    }

    #[test]
    fn move_group_refuses_cycles_and_allows_root_move() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        // 把祖先移到自己的后代下 → 拒绝
        assert!(move_group(prod.id.clone(), Some(east.id.clone())).is_err());
        // 移到自己下 → 拒绝
        assert!(move_group(east.id.clone(), Some(east.id.clone())).is_err());
        // 移到不存在的父下 → 拒绝
        assert!(move_group(east.id.clone(), Some("nope".into())).is_err());
        // 正常移回根级
        assert!(move_group(east.id.clone(), None).is_ok());
    }

    #[test]
    fn delete_group_cascade_moves_hosts_to_root_and_drops_subgroups() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));
        let mut db = password_host("db", "数据库", "db.example.com");
        db.group_id = Some(east.id.clone());
        save_host(db).unwrap();

        delete_group(prod.id.clone()).unwrap();

        assert!(list_groups().unwrap().is_empty(), "子分组应被级联删除");
        let hosts = list_hosts().unwrap();
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].group_id, None, "主机数据应保留并回到根级");
    }

    #[test]
    fn sidebar_tree_orders_groups_first_and_recurses_children() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        save_host(password_host("root-host", "根主机", "root.example.com")).unwrap();
        let mut prod_host = password_host("prod-host", "生产主机", "prod.example.com");
        prod_host.group_id = Some(prod.id.clone());
        save_host(prod_host).unwrap();
        let mut east_host = password_host("east-host", "华东主机", "east.example.com");
        east_host.group_id = Some(east.id.clone());
        save_host(east_host).unwrap();

        let tree = sidebar_tree().unwrap();
        // 根级：分组在前、主机在后
        assert_eq!(tree.len(), 2);
        assert!(tree[0].is_group);
        assert_eq!(tree[0].name, "生产");
        assert!(!tree[1].is_group);
        assert_eq!(tree[1].host.as_ref().unwrap().name, "根主机");
        assert!(tree[1].group.is_none());

        // 生产组：子分组在前、直属主机在后
        let children = tree[0].children.as_ref().unwrap();
        assert_eq!(children.len(), 2);
        assert_eq!(children[0].group.as_ref().unwrap().name, "华东");
        assert_eq!(children[1].host.as_ref().unwrap().name, "生产主机");

        // 华东组递归
        let east_children = children[0].children.as_ref().unwrap();
        assert_eq!(east_children.len(), 1);
        assert_eq!(east_children[0].host.as_ref().unwrap().name, "华东主机");
    }

    #[test]
    fn sidebar_tree_preserves_empty_group_and_orphan_public_key_host_records() {
        let (_lock, _dir) = init_test_store();
        let empty = create_group("空分组", None);

        let mut orphan = key_host("orphan", "孤儿密钥主机", Some("host.orphan.passphrase".into()));
        orphan.group_id = Some("deleted-group".into());
        orphan.notes = Some("应被降级到根级".into());
        save_host(orphan).unwrap();

        let tree = sidebar_tree().unwrap();
        let empty_node = tree
            .iter()
            .find(|node| node.id == format!("group-{}", empty.id))
            .unwrap();
        assert!(empty_node.is_group);
        assert!(empty_node.host.is_none());
        assert_eq!(empty_node.group.as_ref().unwrap().name, "空分组");
        assert!(empty_node.children.is_none(), "空分组必须映射为 None 子节点");

        let orphan_node = tree
            .iter()
            .find(|node| node.id == "host-orphan")
            .unwrap();
        assert!(!orphan_node.is_group);
        assert!(orphan_node.group.is_none());
        assert!(orphan_node.children.is_none());
        let host = orphan_node.host.as_ref().unwrap();
        assert_eq!(host.notes.as_deref(), Some("应被降级到根级"));
        assert!(matches!(
            host.auth,
            AuthMethodEnum::PublicKey {
                ref key_path,
                ref passphrase_ref,
            } if key_path == "/tmp/id_ed25519"
                && passphrase_ref.as_deref() == Some("host.orphan.passphrase")
        ));
    }

    #[test]
    fn config_export_then_import_roundtrip_restores_hosts() {
        let (lock, _dir) = init_test_store();
        save_group(new_group("导出组", None)).unwrap();
        save_host(password_host("h1", "主机一", "one.example.com")).unwrap();
        save_host(password_host("h2", "主机二", "two.example.com")).unwrap();
        let archive_dir = tempfile::tempdir().unwrap();
        let archive_path = archive_dir.path().join("backup.zip");

        let manifest = config_export(archive_path.to_string_lossy().into_owned()).unwrap();
        assert!(
            manifest.file_count >= 2,
            "至少导出 hosts.toml 与 groups.toml"
        );
        assert_eq!(manifest.version, 1);

        // 切换到全新空目录后导入（复用已持有的锁，验证 init_store 可重新初始化）
        let fresh_dir = tempfile::tempdir().unwrap();
        init_store(fresh_dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(list_hosts().unwrap().is_empty());

        let result = config_import(archive_path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(result.host_count, 2);
        // config_import 绕过 store 实例直写磁盘，而 store 带内存缓存：
        // 导入后必须重新 init_store 重建实例才能读到导入结果（App 侧同样如此）。
        init_store(fresh_dir.path().to_string_lossy().into_owned()).unwrap();
        let hosts = list_hosts().unwrap();
        assert_eq!(hosts.len(), 2);
        assert!(hosts.iter().any(|h| h.name == "主机一"));
        drop(lock);
    }

    #[test]
    fn config_import_maps_backup_and_snippet_counts_from_real_archive() {
        let (lock, source_dir) = init_test_store();
        save_group(new_group("源分组", None)).unwrap();
        save_host(password_host("source", "源主机", "source.example.com")).unwrap();
        let source_snippets = source_dir.path().join("snippets");
        init_snippets(source_snippets.to_string_lossy().into_owned()).unwrap();
        save_snippet(SnippetRecord {
            name: "source-snippet".into(),
            title: "源片段".into(),
            tags: vec!["archive".into()],
            body: "echo source".into(),
        })
        .unwrap();
        accept_unknown_host_key("source.example.com".into(), 22, TEST_KEY.into()).unwrap();

        let archive_dir = tempfile::tempdir().unwrap();
        let archive_path = archive_dir.path().join("source.zip");
        let manifest = config_export(archive_path.to_string_lossy().into_owned()).unwrap();
        assert!(manifest.file_count >= 4, "应导出主机、分组、known_hosts 与片段");
        assert!(!manifest.timestamp.is_empty());
        assert!(!manifest.device_name.is_empty());

        let destination_dir = tempfile::tempdir().unwrap();
        init_store(destination_dir.path().to_string_lossy().into_owned()).unwrap();
        save_group(new_group("旧分组", None)).unwrap();
        save_host(password_host("old", "旧主机", "old.example.com")).unwrap();
        accept_unknown_host_key("old.example.com".into(), 22, TEST_KEY.into()).unwrap();

        let result = config_import(archive_path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(result.host_count, 1);
        assert_eq!(result.group_count, 1);
        assert_eq!(result.snippet_count, 1);
        assert!(result.backup_files.iter().any(|name| name.starts_with("hosts.toml.bak.")));
        assert!(result.backup_files.iter().any(|name| name.starts_with("groups.toml.bak.")));
        assert!(result.backup_files.iter().any(|name| name.starts_with("known_hosts.bak.")));

        init_store(destination_dir.path().to_string_lossy().into_owned()).unwrap();
        assert_eq!(list_hosts().unwrap().len(), 1);
        assert_eq!(list_groups().unwrap().len(), 1);
        init_snippets(destination_dir.path().join("snippets").to_string_lossy().into_owned()).unwrap();
        assert_eq!(list_snippets().unwrap().len(), 1);
        drop(lock);
    }

    /// 2.3 FFI 回归测试：恶意归档通过 FFI 返回 PandaError::Core 错误。
    #[test]
    fn config_import_rejects_unsafe_archive_via_ffi() {
        let (lock, _dir) = init_test_store();

        // 构建含路径逃逸条目的恶意归档
        let archive_dir = tempfile::tempdir().unwrap();
        let zip_path = archive_dir.path().join("evil.zip");
        {
            let file = std::fs::File::create(&zip_path).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();
            zip.start_file("manifest.json", options).unwrap();
            zip.write_all(
                b"{\"version\": 1, \"timestamp\": \"\", \"device_name\": \"\", \"file_count\": 2}",
            )
            .unwrap();
            zip.start_file("hosts.toml", options).unwrap();
            zip.write_all(b"").unwrap();
            zip.start_file("groups.toml", options).unwrap();
            zip.write_all(b"").unwrap();
            zip.start_file("../攻击者控制的名称\\n伪造提示", options)
                .unwrap();
            zip.write_all(b"pwned").unwrap();
            zip.finish().unwrap();
        }

        let err = config_import(zip_path.to_string_lossy().into_owned()).unwrap_err();
        assert!(
            matches!(err, PandaError::Core(ref msg) if msg == "unsafe archive entry"),
            "FFI 应透传 core 安全错误，实际：{err:?}"
        );

        // 失败导入后 store 仍可正常操作（不污染后续合法导入）
        let hosts = list_hosts().unwrap();
        assert!(hosts.is_empty(), "失败导入不应产生主机");
        drop(lock);
    }

    #[test]
    fn snippet_crud_roundtrip() {
        let (_lock, dir) = init_test_store();
        init_snippets(dir.path().join("snippets").to_string_lossy().into_owned()).unwrap();

        let snippet = SnippetRecord {
            name: "重启服务".into(),
            title: "systemctl 重启".into(),
            tags: vec!["systemd".into()],
            body: "sudo systemctl restart app".into(),
        };
        save_snippet(snippet.clone()).unwrap();
        assert_eq!(list_snippets().unwrap(), vec![snippet]);

        delete_snippet("重启服务".into()).unwrap();
        assert!(list_snippets().unwrap().is_empty());
    }

    #[test]
    fn delete_host_clears_credential_entries_and_tolerates_unknown_id() {
        let (_lock, _dir) = init_test_store();
        save_host(password_host("victim", "待删", "victim.example.com")).unwrap();
        save_credential("host.victim.password".into(), "secret".into()).unwrap();
        save_credential("host.victim.passphrase".into(), "phrase".into()).unwrap();

        delete_host("victim".into()).unwrap();
        assert!(list_hosts().unwrap().iter().all(|h| h.id != "victim"));
        assert_eq!(
            read_credential("host.victim.password".into()).unwrap(),
            None
        );
        assert_eq!(
            read_credential("host.victim.passphrase".into()).unwrap(),
            None
        );

        // 未知 id 也为可删除的 no-op（config.delete 对不存在条目不报错）
        delete_host("ghost".into()).unwrap();
    }

    #[test]
    fn save_host_with_empty_id_generates_a_persisted_identifier() {
        let (_lock, _dir) = init_test_store();
        let mut host = password_host("", "自动编号", "generated.example.com");
        host.id.clear();

        save_host(host).unwrap();

        let hosts = list_hosts().unwrap();
        assert_eq!(hosts.len(), 1);
        assert!(!hosts[0].id.is_empty(), "空 id 必须由 FFI 生成 UUID");
        assert_eq!(hosts[0].name, "自动编号");
    }

    // --- Unix 文件权限测试 ---

    #[cfg(unix)]
    fn dir_mode(path: &std::path::Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[cfg(unix)]
    fn file_mode(path: &std::path::Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[cfg(unix)]
    #[test]
    fn unix_init_store_creates_directory_with_restricted_permissions() {
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("panda-config");
        // 目录尚不存在
        assert!(!config_dir.exists());

        init_store(config_dir.to_string_lossy().into_owned()).unwrap();

        assert!(config_dir.exists());
        assert_eq!(
            dir_mode(&config_dir),
            0o700,
            "init_store 创建的专属配置目录权限应为 0700"
        );
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn unix_init_store_tightens_existing_loose_directory() {
        use std::os::unix::fs::PermissionsExt;
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("panda-config");
        // 预置宽松权限的配置目录
        std::fs::create_dir_all(&config_dir).unwrap();
        std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(dir_mode(&config_dir), 0o755);

        init_store(config_dir.to_string_lossy().into_owned()).unwrap();

        assert_eq!(
            dir_mode(&config_dir),
            0o700,
            "init_store 应将既有宽松目录收紧为 0700"
        );
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn unix_init_store_fixes_existing_loose_credential_file() {
        use std::os::unix::fs::PermissionsExt;
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("panda-config");
        std::fs::create_dir_all(&config_dir).unwrap();
        let cred_path = config_dir.join("credentials.toml");
        // 预置宽松权限的凭据文件
        std::fs::write(
            &cred_path,
            "version = 1\n[entries]\n\"host.a.password\" = \"legacy\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&cred_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(file_mode(&cred_path), 0o644);

        init_store(config_dir.to_string_lossy().into_owned()).unwrap();

        assert_eq!(
            file_mode(&cred_path),
            0o600,
            "init_store 应将既有宽松凭据文件收紧为 0600"
        );
        // 内容不变
        let text = std::fs::read_to_string(&cred_path).unwrap();
        assert!(text.contains("legacy"));
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn unix_init_store_succeeds_without_credential_file() {
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("panda-config");
        std::fs::create_dir_all(&config_dir).unwrap();
        // 不存在 credentials.toml — 边界情况，不应报错
        assert!(!config_dir.join("credentials.toml").exists());

        init_store(config_dir.to_string_lossy().into_owned()).unwrap();

        assert_eq!(dir_mode(&config_dir), 0o700);
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn unix_init_store_tightens_legacy_regular_temporary_credential_file() {
        use std::os::unix::fs::PermissionsExt;

        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("panda-config");
        std::fs::create_dir_all(&config_dir).unwrap();
        let legacy_tmp = config_dir.join("credentials.tmp");
        std::fs::write(&legacy_tmp, "legacy temporary credential data").unwrap();
        std::fs::set_permissions(&legacy_tmp, std::fs::Permissions::from_mode(0o644)).unwrap();

        init_store(config_dir.to_string_lossy().into_owned()).unwrap();

        assert_eq!(file_mode(&legacy_tmp), 0o600);
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn unix_directory_permission_policy_matches_platform_container_ownership() {
        assert_eq!(
            should_restrict_config_directory_permissions(),
            !cfg!(target_os = "ios")
        );
    }

    // --- 保护状态与只解锁 FFI 测试 ---

    #[test]
    fn protection_status_unprotected_by_default() {
        let (_lock, _dir) = init_test_store();
        assert!(matches!(
            credential_protection_status().unwrap(),
            ProtectionStatusEnum::Unprotected
        ));
    }

    #[test]
    fn protection_status_locked_after_restart_and_unlock_with_correct_key() {
        let (_lock, _dir) = init_test_store();
        save_credential("host.test.password".into(), "secret".into()).unwrap();
        set_credential_protection_key(None, Some("protect".into())).unwrap();

        // 重新初始化模拟重启
        init_store(_dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(matches!(
            credential_protection_status().unwrap(),
            ProtectionStatusEnum::ProtectedLocked
        ));

        // 错误密钥不解锁
        let status = credential_unlock_only("wrong".into()).unwrap();
        assert!(matches!(status, ProtectionStatusEnum::ProtectedLocked));

        // 正确密钥解锁
        let status = credential_unlock_only("protect".into()).unwrap();
        assert!(matches!(status, ProtectionStatusEnum::ProtectedUnlocked));

        // 解锁后可读取
        assert_eq!(
            read_credential("host.test.password".into()).unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn protection_status_does_not_mask_corrupted_file() {
        let (lock, dir) = init_test_store();
        let cred_path = dir.path().join("credentials.toml");
        std::fs::write(&cred_path, "[broken").unwrap();
        drop(lock);

        assert!(credential_protection_status().is_err());
    }

    #[test]
    fn validate_protection_input_enable_change_remove_via_ffi() {
        // 启用
        let action = validate_credential_protection_input(
            None,
            Some("new".into()),
            Some("new".into()),
            false,
        )
        .unwrap();
        assert!(matches!(action, ProtectionActionEnum::Enable));

        // 不一致
        let err = validate_credential_protection_input(
            None,
            Some("a".into()),
            Some("b".into()),
            false,
        )
        .unwrap_err();
        assert!(matches!(err, ProtectionInputErrorEnum::ConfirmMismatch));

        // 更换
        let action = validate_credential_protection_input(
            Some("old".into()),
            Some("new".into()),
            Some("new".into()),
            true,
        )
        .unwrap();
        assert!(matches!(action, ProtectionActionEnum::ChangeKey));

        // 移除
        let action =
            validate_credential_protection_input(Some("old".into()), None, None, true).unwrap();
        assert!(matches!(action, ProtectionActionEnum::Remove));

        // 未保护时移除
        let err = validate_credential_protection_input(None, None, None, false).unwrap_err();
        assert!(matches!(err, ProtectionInputErrorEnum::AlreadyUnprotected));

        // 受保护时缺少当前密码。
        let err = validate_credential_protection_input(None, Some("new".into()), Some("new".into()), true)
            .unwrap_err();
        assert!(matches!(err, ProtectionInputErrorEnum::CurrentKeyRequired));

        assert_eq!(ProtectionInputErrorEnum::ConfirmMismatch.to_string(), "新密码与确认密码不一致");
        assert_eq!(ProtectionInputErrorEnum::CurrentKeyRequired.to_string(), "需要提供当前密码");
        assert_eq!(ProtectionInputErrorEnum::AlreadyUnprotected.to_string(), "凭据未受保护");
    }

    #[test]
    fn terminal_buffer_default_and_validate_via_ffi() {
        assert_eq!(default_terminal_buffer_lines(), 10000);

        assert_eq!(validate_terminal_buffer_lines("5000".into()).unwrap(), 5000);
        assert_eq!(validate_terminal_buffer_lines("".into()).unwrap(), 10000);

        assert!(matches!(
            validate_terminal_buffer_lines("abc".into()),
            Err(TerminalBufferErrorEnum::NotANumber)
        ));
        assert!(matches!(
            validate_terminal_buffer_lines("500".into()),
            Err(TerminalBufferErrorEnum::OutOfRange)
        ));
        assert!(matches!(
            validate_terminal_buffer_lines("200000".into()),
            Err(TerminalBufferErrorEnum::OutOfRange)
        ));
        assert_eq!(TerminalBufferErrorEnum::NotANumber.to_string(), "输入不是有效整数");
        assert_eq!(
            TerminalBufferErrorEnum::OutOfRange.to_string(),
            "输入超出允许范围 1000–100000"
        );
    }

    #[test]
    fn group_record_round_trip_preserves_root_and_nested_parent() {
        let root = GroupRecord { id: "root".into(), name: "根".into(), parent_id: None };
        let nested = GroupRecord { id: "child".into(), name: "子".into(), parent_id: Some("root".into()) };
        let root_round_trip = GroupRecord::from(Group::from(root));
        let nested_round_trip = GroupRecord::from(Group::from(nested));
        assert_eq!(root_round_trip.parent_id, None);
        assert_eq!(nested_round_trip.parent_id.as_deref(), Some("root"));
    }

    #[test]
    fn store_helpers_expose_not_initialized_and_unknown_host() {
        let _guard = global_test_lock();
        *STORES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        assert!(matches!(stores(), Err(PandaError::NotInitialized)));
        let dir = tempfile::tempdir().unwrap();
        init_store(dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(matches!(load_host("missing"), Err(PandaError::UnknownHost(id)) if id == "missing"));
    }

    #[test]
    fn snippet_helpers_report_not_initialized_then_support_empty_store() {
        let _guard = global_test_lock();
        *SNIPPET_STORE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        assert!(matches!(snippet_store(), Err(PandaError::NotInitialized)));
        assert!(matches!(list_snippets(), Err(PandaError::NotInitialized)));
        assert!(matches!(delete_snippet("missing".into()), Err(PandaError::NotInitialized)));

        let dir = tempfile::tempdir().unwrap();
        init_snippets(dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(list_snippets().unwrap().is_empty());
        delete_snippet("missing".into()).unwrap();
    }
