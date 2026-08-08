//! 真实 SSH/SFTP 服务器连通性集成测试。
//!
//! 这些测试依赖外部服务器 `lwq@100.78.247.105`，默认不运行；
//! 执行时请加 `--ignored`：
//!
//! ```sh
//! cargo test -p panda-core --test real_server -- --ignored
//! ```
//!
//! 如果私钥路径与默认不同，可通过环境变量覆盖：
//! `PANDA_SSH_TEST_KEY`（默认 `/Users/luowenqiang/files/protected-files/keys/ssh_rsa`）。

use std::path::PathBuf;

use panda_core::{
    AuthMethod, Credentials, HostConfig, KnownHosts, SftpClient, SshSession,
    UnknownHostKeyPolicy,
};

const HOST: &str = "100.78.247.105";
const PORT: u16 = 22;
const USERNAME: &str = "lwq";
const REMOTE_DIR: &str = "/share/homes/lwq/ssh-test";
const DEFAULT_KEY: &str = "/Users/luowenqiang/files/protected-files/keys/luo_wenqiang@qq.com";

fn test_cfg() -> HostConfig {
    HostConfig {
        id: "real-server".into(),
        name: "real-server".into(),
        host: HOST.into(),
        port: PORT,
        username: USERNAME.into(),
        auth: AuthMethod::PublicKey {
            key_path: key_path(),
            passphrase_ref: None,
        },
        notes: None,
        group_id: None,
    }
}

fn key_path() -> PathBuf {
    std::env::var("PANDA_SSH_TEST_KEY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_KEY))
}

fn known_hosts(dir: &std::path::Path) -> KnownHosts {
    KnownHosts::new(dir.join("known_hosts"))
}

#[tokio::test]
#[ignore = "requires real SSH server"]
async fn ssh_connect_and_exec_pwd() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = test_cfg();
    let creds = Credentials::KeyFile {
        path: key_path(),
        passphrase: None,
    };
    let mut kh = known_hosts(dir.path());

    let session = SshSession::connect(&cfg, creds, &mut kh, UnknownHostKeyPolicy::AcceptAndStore)
        .await
        .expect("SSH 连接失败；若提示 Timeout，请检查 App/测试进程是否能访问私钥与网络");

    let output = session.exec("pwd").await.expect("exec pwd 失败");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("/homes/lwq"),
        "unexpected pwd: {stdout}");

    session.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "requires real SSH server"]
async fn sftp_home_dir_matches_pwd() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = test_cfg();
    let creds = Credentials::KeyFile {
        path: key_path(),
        passphrase: None,
    };
    let mut kh = known_hosts(dir.path());

    let session = SshSession::connect(&cfg, creds, &mut kh, UnknownHostKeyPolicy::AcceptAndStore)
        .await
        .expect("SSH 连接失败");
    let sftp = SftpClient::new(&session).await.expect("SFTP 子系统初始化失败");

    let home = sftp.home_dir().await.expect("获取 SFTP home 目录失败");
    assert!(home.contains("/homes/lwq"), "unexpected home: {home}");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "requires real SSH server"]
async fn sftp_list_remote_dir() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = test_cfg();
    let creds = Credentials::KeyFile {
        path: key_path(),
        passphrase: None,
    };
    let mut kh = known_hosts(dir.path());

    let session = SshSession::connect(&cfg, creds, &mut kh, UnknownHostKeyPolicy::AcceptAndStore)
        .await
        .expect("SSH 连接失败");
    let sftp = SftpClient::new(&session).await.expect("SFTP 子系统初始化失败");

    let entries = sftp.list_dir(REMOTE_DIR).await.expect("列出远程目录失败");
    // 目录存在即可，不强制内容。
    assert!(!entries.iter().any(|e| e.name == "." || e.name == ".."), "应过滤掉 . 和 ..");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "requires real SSH server"]
async fn sftp_upload_and_download_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let local = dir.path().join("payload.txt");
    std::fs::write(&local, b"panda real server test").unwrap();

    let cfg = test_cfg();
    let creds = Credentials::KeyFile {
        path: key_path(),
        passphrase: None,
    };
    let mut kh = known_hosts(dir.path());

    let session = SshSession::connect(&cfg, creds, &mut kh, UnknownHostKeyPolicy::AcceptAndStore)
        .await
        .expect("SSH 连接失败");
    let sftp = SftpClient::new(&session).await.expect("SFTP 子系统初始化失败");

    let remote = format!("{REMOTE_DIR}/panda-test-payload.txt");
    sftp.upload(&local, &remote, None).await.expect("上传失败");

    let downloaded = dir.path().join("downloaded.txt");
    sftp.download(&remote, &downloaded).await.expect("下载失败");

    assert_eq!(
        std::fs::read_to_string(&downloaded).unwrap(),
        "panda real server test"
    );

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}
