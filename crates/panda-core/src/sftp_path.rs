//! SFTP 浏览与传输共享的路径规则，不依赖客户端操作系统。

use crate::{Error, Result};

/// 地址栏仅接受绝对路径；保留空格、点段及符号链接的服务器解析语义。
pub fn directory_path(input: &str) -> Result<String> {
    if !input.starts_with('/') || input.contains('\0') {
        return Err(Error::Other(
            "请输入以 / 开头且不含 NUL 的完整绝对路径".into(),
        ));
    }
    let path = input.trim_end_matches('/');
    Ok(if path.is_empty() { "/" } else { path }.into())
}

/// 将目录与已列举的条目名连接，保留名称中的空格及非 ASCII 字符。
pub fn join_path(dir: &str, name: &str) -> String {
    if name.is_empty() {
        dir.to_owned()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}
