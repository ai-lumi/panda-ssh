use panda_ffi::{sftp_child_path, sftp_directory_path, PandaError};

#[test]
fn address_and_transfer_share_the_ffi_path_contract() {
    let directory = sftp_directory_path("/var/中文 目录///".into()).unwrap();
    assert_eq!(directory, "/var/中文 目录");
    assert_eq!(
        sftp_child_path(directory, "中文 文件.txt ".into()),
        "/var/中文 目录/中文 文件.txt "
    );
}

#[test]
fn invalid_addresses_remain_structured_ffi_errors() {
    for path in ["", "relative", "~/logs", "/bad\0path"] {
        assert!(matches!(
            sftp_directory_path(path.into()),
            Err(PandaError::Core(_))
        ));
    }
}

#[test]
fn root_and_symbolic_link_paths_keep_their_meaning_across_ffi() {
    let root = sftp_directory_path("///".into()).unwrap();
    assert_eq!(sftp_child_path(root, "a.txt".into()), "/a.txt");
    let path = sftp_directory_path("/alias/../data/".into()).unwrap();
    assert_eq!(
        sftp_child_path(path, "a.txt".into()),
        "/alias/../data/a.txt"
    );
}
