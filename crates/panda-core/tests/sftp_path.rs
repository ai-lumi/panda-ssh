use panda_core::sftp_path::{directory_path, join_path};

#[test]
fn absolute_directory_preserves_names_and_server_resolution() {
    for path in ["/var/log", "/中文 目录 ", "/a/link/../data", "/a/./data"] {
        assert_eq!(directory_path(path).unwrap(), path);
    }
}

#[test]
fn directory_rejects_empty_relative_and_nul() {
    for path in ["", " ", "logs", "../logs", "~/logs", "/var/\0log"] {
        assert!(directory_path(path).is_err(), "{path:?}");
    }
}

#[test]
fn directory_and_child_handle_root_and_trailing_separators() {
    for (input, expected) in [("/", "/"), ("///", "/"), ("/var/log///", "/var/log")] {
        assert_eq!(directory_path(input).unwrap(), expected);
    }
    for (dir, name, expected) in [
        ("/", "a.txt", "/a.txt"),
        ("///", "a.txt", "/a.txt"),
        ("/var/log///", "中文 文件.txt ", "/var/log/中文 文件.txt "),
        ("/var/log", "a", "/var/log/a"),
        ("/var/log", "", "/var/log"),
    ] {
        assert_eq!(join_path(dir, name), expected);
    }
}
