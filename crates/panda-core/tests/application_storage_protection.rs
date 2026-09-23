#[cfg(unix)]
mod unix {
    use std::os::unix::fs::{symlink, PermissionsExt};

    use panda_core::{PandaCore, StorageLocation};

    fn mode(path: &std::path::Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn private_core_root_tightens_directory_and_existing_credential_permissions() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("private-config");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let credential = root.join("credentials.toml");
        std::fs::write(&credential, "version = 1\n[entries]\n").unwrap();
        std::fs::set_permissions(&credential, std::fs::Permissions::from_mode(0o644)).unwrap();

        PandaCore::new(&root).unwrap();

        assert_eq!(mode(&root), 0o700);
        assert_eq!(mode(&credential), 0o600);
    }

    #[test]
    fn core_rejects_a_credential_symlink_without_following_it() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("private-config");
        std::fs::create_dir(&root).unwrap();
        let target = parent.path().join("target");
        std::fs::write(&target, "must not be changed").unwrap();
        symlink(&target, root.join("credentials.toml")).unwrap();

        assert!(PandaCore::new(&root).is_err());
        assert_eq!(std::fs::read_to_string(target).unwrap(), "must not be changed");
    }

    #[test]
    fn core_rejects_a_credential_directory() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("private-config");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(root.join("credentials.toml")).unwrap();

        assert!(PandaCore::new(&root).is_err());
    }

    #[test]
    fn platform_container_preserves_directory_mode_but_still_protects_credentials() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("app-group");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let credential = root.join("credentials.toml");
        std::fs::write(&credential, "version = 1\n[entries]\n").unwrap();
        std::fs::set_permissions(&credential, std::fs::Permissions::from_mode(0o644)).unwrap();

        PandaCore::new_with_storage_location(&root, StorageLocation::PlatformContainer).unwrap();

        assert_eq!(mode(&root), 0o755);
        assert_eq!(mode(&credential), 0o600);
    }
}
