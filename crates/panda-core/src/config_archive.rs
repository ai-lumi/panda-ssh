//! 配置导入导出：将配置目录打包为 ZIP 归档，或从归档恢复。

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 导出归档的 manifest。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportManifest {
    pub version: u32,
    pub timestamp: String,
    pub device_name: String,
    pub file_count: u32,
}

/// 导入结果。
#[derive(Debug, Clone)]
pub struct ImportResult {
    pub backup_files: Vec<String>,
    pub host_count: u32,
    pub group_count: u32,
    pub snippet_count: u32,
}

/// 导入错误。
#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("archive is missing manifest.json")]
    MissingManifest,
    #[error("manifest version {0} is not supported (expected 1)")]
    VersionMismatch(u32),
    #[error("archive is missing required file: {0}")]
    MissingRequiredFile(String),
    #[error("unsafe archive entry")]
    UnsafeEntry(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
}

const CURRENT_VERSION: u32 = 1;
const REQUIRED_FILES: &[&str] = &["hosts.toml", "groups.toml"];

/// 将配置目录导出为 ZIP 归档。
///
/// `config_dir` 是配置根目录（包含 hosts.toml、groups.toml、known_hosts、snippets/）。
/// `output_path` 是输出 ZIP 文件路径。
pub fn config_export(config_dir: &Path, output_path: &Path) -> Result<ExportManifest, ImportError> {
    let file = fs::File::create(output_path)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let mut file_count = 0u32;

    // 写入必需配置文件
    for name in &["hosts.toml", "groups.toml", "known_hosts"] {
        let path = config_dir.join(name);
        if path.exists() {
            zip.start_file(name, options)?;
            let mut content = Vec::new();
            fs::File::open(&path)?.read_to_end(&mut content)?;
            zip.write_all(&content)?;
            file_count += 1;
        }
    }

    // 写入 snippets 目录
    let snippets_dir = config_dir.join("snippets");
    if snippets_dir.is_dir() {
        for entry in fs::read_dir(&snippets_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_file() {
                let name = format!("snippets/{}", path.file_name().unwrap().to_string_lossy());
                zip.start_file(&name, options)?;
                let mut content = Vec::new();
                fs::File::open(&path)?.read_to_end(&mut content)?;
                zip.write_all(&content)?;
                file_count += 1;
            }
        }
    }

    // 生成并写入 manifest
    let device_name = hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "unknown".to_string());

    let timestamp = chrono_now();
    let manifest = ExportManifest {
        version: CURRENT_VERSION,
        timestamp,
        device_name,
        file_count,
    };
    let manifest_json = serde_json::to_string_pretty(&manifest)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    zip.start_file("manifest.json", options)?;
    zip.write_all(manifest_json.as_bytes())?;

    zip.finish()?;
    Ok(manifest)
}

/// 从 ZIP 归档导入配置到配置目录。
///
/// 导入前会对已有文件进行带时间戳的备份。
///
/// # 安全校验
///
/// 第一阶段（预检）：遍历归档全部条目，验证每个条目名是否在允许集合内：
/// - `manifest.json`（唯一）
/// - `hosts.toml`、`groups.toml`（唯一）
/// - `known_hosts`（可选，唯一）
/// - `snippets/<filename>`（`<filename>` 为单一非空文件名，无子目录）
///
/// 拒绝绝对路径、父目录组件、目录条目、歧义分隔符、重复目标。
/// 任何失败立即返回错误，不触发配置目录创建、备份或写入。
///
/// 第二阶段（提取）：仅使用预检通过的相对路径进行备份和写入。
pub fn config_import(config_dir: &Path, archive_path: &Path) -> Result<ImportResult, ImportError> {
    let file = fs::File::open(archive_path)?;
    let mut zip = zip::ZipArchive::new(file)?;

    // ── 第一阶段：预检（无副作用） ──

    // 读取并校验 manifest
    let manifest: ExportManifest = {
        let mut manifest_file = zip
            .by_name("manifest.json")
            .map_err(|_| ImportError::MissingManifest)?;
        let mut json = String::new();
        manifest_file.read_to_string(&mut json)?;
        serde_json::from_str(&json)
            .map_err(|_| ImportError::MissingManifest)
            .and_then(|m: ExportManifest| {
                if m.version != CURRENT_VERSION {
                    Err(ImportError::VersionMismatch(m.version))
                } else {
                    Ok(m)
                }
            })?
    };

    // 校验必需文件
    let has_required = REQUIRED_FILES
        .iter()
        .all(|req| zip.file_names().any(|n| n == *req));
    if !has_required {
        let missing = REQUIRED_FILES
            .iter()
            .find(|req| !zip.file_names().any(|n| n == **req))
            .unwrap();
        return Err(ImportError::MissingRequiredFile(missing.to_string()));
    }

    // 验证全部条目并收集合法目标
    let allowed_entries = validate_archive_entries(&mut zip)?;
    // 在任何配置目录变更前完整读取并校验允许条目的内容（包括 CRC）。
    let archive_entries = read_archive_entries(&mut zip, &allowed_entries)?;

    // ── 第二阶段：提取（仅使用预检结果） ──

    fs::create_dir_all(config_dir)?;

    let mut backup_files = Vec::new();
    let mut snippet_count = 0u32;
    let timestamp = backup_timestamp();

    for (target_name, content) in archive_entries {
        // 跳过 manifest（已在预检中读取）
        if target_name == "manifest.json" {
            continue;
        }

        let target_path = config_dir.join(&target_name);

        // 备份已有文件
        if target_path.exists() {
            let backup_name = format!(
                "{}.bak.{}",
                target_path.file_name().unwrap().to_string_lossy(),
                timestamp
            );
            let backup_path = config_dir.join(&backup_name);
            fs::rename(&target_path, &backup_path)?;
            backup_files.push(backup_name);
        }

        // 创建父目录（仅 snippets/）
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent)?;
        }

        // 写入已在预检阶段完成完整性校验的内容
        fs::write(&target_path, &content)?;

        if target_name.starts_with("snippets/") {
            snippet_count += 1;
        }
    }

    // 统计主机和分组数量（简单计数）
    let host_count = count_toml_entries(config_dir.join("hosts.toml"), "id");
    let group_count = count_toml_entries(config_dir.join("groups.toml"), "id");

    let _ = manifest; // manifest 已校验
    Ok(ImportResult {
        backup_files,
        host_count,
        group_count,
        snippet_count,
    })
}

/// 验证归档全部条目是否在允许集合内，返回合法条目的 (索引, 目标名) 列表。
///
/// 允许集合：
/// - `manifest.json`（唯一）
/// - `hosts.toml`、`groups.toml`（唯一）
/// - `known_hosts`（可选，唯一）
/// - `snippets/<filename>`（`<filename>` 为单一非空文件名，无子目录）
///
/// 拒绝：绝对路径、`..` 组件、目录条目、歧义分隔符、重复目标。
fn validate_archive_entries(
    zip: &mut zip::ZipArchive<fs::File>,
) -> Result<Vec<(usize, String)>, ImportError> {
    // 允许的根文件（唯一）
    const ALLOWED_ROOT_FILES: &[&str] =
        &["manifest.json", "hosts.toml", "groups.toml", "known_hosts"];

    let mut seen_targets: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut allowed_entries: Vec<(usize, String)> = Vec::new();

    for i in 0..zip.len() {
        let name = zip.by_index_raw(i)?.name().to_string();

        // 拒绝空名称
        if name.is_empty() {
            return Err(ImportError::UnsafeEntry(name));
        }

        // 拒绝绝对路径
        if name.starts_with('/') || name.starts_with('\\') {
            return Err(ImportError::UnsafeEntry(name));
        }

        // 拒绝目录条目（以 `/` 或 `\` 结尾）
        if name.ends_with('/') || name.ends_with('\\') {
            return Err(ImportError::UnsafeEntry(name));
        }

        // 拒绝包含反斜杠的歧义路径
        if name.contains('\\') {
            return Err(ImportError::UnsafeEntry(name));
        }

        // 拒绝包含 `..` 组件的路径
        if name.split('/').any(|c| c == ".." || c == ".") {
            return Err(ImportError::UnsafeEntry(name));
        }

        // 确定目标类别
        let target = if ALLOWED_ROOT_FILES.contains(&name.as_str()) {
            // 根文件
            name.clone()
        } else if let Some(snippet_name) = name.strip_prefix("snippets/") {
            // snippets/ 下的文件：必须是单一非空文件名，无额外层级
            if snippet_name.is_empty() || snippet_name.contains('/') {
                return Err(ImportError::UnsafeEntry(name));
            }
            name.clone()
        } else {
            // 不在允许集合内
            return Err(ImportError::UnsafeEntry(name));
        };

        // 检测重复目标
        if !seen_targets.insert(target.clone()) {
            return Err(ImportError::UnsafeEntry(name));
        }

        allowed_entries.push((i, target));
    }

    Ok(allowed_entries)
}

/// 完整读取预检通过的非 manifest 条目，在变更配置目录前触发 ZIP 解压和 CRC 错误。
fn read_archive_entries(
    zip: &mut zip::ZipArchive<fs::File>,
    allowed_entries: &[(usize, String)],
) -> Result<Vec<(String, Vec<u8>)>, ImportError> {
    let mut entries = Vec::with_capacity(allowed_entries.len().saturating_sub(1));

    for (entry_index, target_name) in allowed_entries {
        if target_name == "manifest.json" {
            continue;
        }

        let mut entry = zip.by_index(*entry_index)?;
        let mut content = Vec::new();
        entry.read_to_end(&mut content)?;
        entries.push((target_name.clone(), content));
    }

    Ok(entries)
}

/// 简单时间戳（不依赖 chrono crate）。
fn chrono_now() -> String {
    use std::time::SystemTime;
    let dur = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();
    // 简单 ISO 8601 格式（UTC）
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    // 从 Unix epoch (1970-01-01) 计算年月日
    let (year, month, day) = days_to_ymd(days as i64);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn backup_timestamp() -> String {
    use std::time::SystemTime;
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}", secs)
}

/// 将 Unix 天数转换为 (year, month, day)。
fn days_to_ymd(mut days: i64) -> (i64, u32, u32) {
    // 简化算法
    let mut year = 1970;
    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }
    let leap = is_leap_year(year);
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 1u32;
    for &md in &month_days {
        if days < md {
            break;
        }
        days -= md;
        month += 1;
    }
    (year, month, days as u32 + 1)
}

fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// 简单统计 TOML 文件中某个键出现的次数（用于估算主机/分组数量）。
fn count_toml_entries(path: PathBuf, key: &str) -> u32 {
    match fs::read_to_string(&path) {
        Ok(content) => {
            content.matches(&format!("\n{} = ", key)).count() as u32
                + if content.starts_with(&format!("{} = ", key)) {
                    1
                } else {
                    0
                }
        }
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_config_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("hosts.toml"),
            "[[hosts]]\nid = \"h1\"\nname = \"test\"\n",
        )
        .unwrap();
        fs::write(
            dir.path().join("groups.toml"),
            "[[groups]]\nid = \"g1\"\nname = \"prod\"\n",
        )
        .unwrap();
        fs::write(
            dir.path().join("known_hosts"),
            "example.com ssh-ed25519 AAAA\n",
        )
        .unwrap();
        let snippets = dir.path().join("snippets");
        fs::create_dir(&snippets).unwrap();
        fs::write(snippets.join("test.md"), "---\ntitle: Test\n---\nHello\n").unwrap();
        dir
    }

    #[test]
    fn export_creates_valid_zip() {
        let dir = setup_config_dir();
        let output = dir.path().join("export.zip");
        let manifest = config_export(dir.path(), &output).unwrap();
        assert_eq!(manifest.version, 1);
        assert!(manifest.file_count >= 4); // hosts + groups + known_hosts + 1 snippet
        assert!(!manifest.device_name.is_empty());
        assert!(!manifest.timestamp.is_empty());

        // 验证 ZIP 内容
        let file = fs::File::open(&output).unwrap();
        let mut zip = zip::ZipArchive::new(file).unwrap();
        assert!(zip.by_name("manifest.json").is_ok());
        assert!(zip.by_name("hosts.toml").is_ok());
        assert!(zip.by_name("groups.toml").is_ok());
        assert!(zip.by_name("known_hosts").is_ok());
        assert!(zip.by_name("snippets/test.md").is_ok());
    }

    #[test]
    fn import_restores_files() {
        let src = setup_config_dir();
        let zip_path = src.path().join("export.zip");
        config_export(src.path(), &zip_path).unwrap();

        let dst = TempDir::new().unwrap();
        let result = config_import(dst.path(), &zip_path).unwrap();
        assert!(dst.path().join("hosts.toml").exists());
        assert!(dst.path().join("groups.toml").exists());
        assert!(dst.path().join("known_hosts").exists());
        assert!(dst.path().join("snippets/test.md").exists());
        assert_eq!(result.snippet_count, 1);
    }

    #[test]
    fn import_backs_up_existing_files() {
        let src = setup_config_dir();
        let zip_path = src.path().join("export.zip");
        config_export(src.path(), &zip_path).unwrap();

        let dst = setup_config_dir(); // 已有文件
        let result = config_import(dst.path(), &zip_path).unwrap();
        assert!(!result.backup_files.is_empty());
    }

    #[test]
    fn import_rejects_version_mismatch() {
        let dir = TempDir::new().unwrap();
        let zip_path = dir.path().join("bad.zip");
        let file = fs::File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(
            b"{\"version\": 99, \"timestamp\": \"\", \"device_name\": \"\", \"file_count\": 0}",
        )
        .unwrap();
        zip.start_file("hosts.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        zip.start_file("groups.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        zip.finish().unwrap();

        let dst = TempDir::new().unwrap();
        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::VersionMismatch(99)));
    }

    #[test]
    fn import_rejects_missing_required_file() {
        let dir = TempDir::new().unwrap();
        let zip_path = dir.path().join("incomplete.zip");
        let file = fs::File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(
            b"{\"version\": 1, \"timestamp\": \"\", \"device_name\": \"\", \"file_count\": 0}",
        )
        .unwrap();
        zip.start_file("hosts.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        // 缺少 groups.toml
        zip.finish().unwrap();

        let dst = TempDir::new().unwrap();
        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::MissingRequiredFile(_)));
    }

    #[test]
    fn import_rejects_missing_manifest() {
        let dir = TempDir::new().unwrap();
        let zip_path = dir.path().join("no_manifest.zip");
        let file = fs::File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("hosts.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        zip.finish().unwrap();

        let dst = TempDir::new().unwrap();
        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::MissingManifest));
    }

    #[test]
    fn non_ascii_filenames_survive_roundtrip() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("hosts.toml"), "").unwrap();
        fs::write(dir.path().join("groups.toml"), "").unwrap();
        let snippets = dir.path().join("snippets");
        fs::create_dir(&snippets).unwrap();
        fs::write(snippets.join("笔记.md"), "# 测试\n").unwrap();

        let zip_path = dir.path().join("unicode.zip");
        config_export(dir.path(), &zip_path).unwrap();

        let dst = TempDir::new().unwrap();
        config_import(dst.path(), &zip_path).unwrap();
        let content = fs::read_to_string(dst.path().join("snippets/笔记.md")).unwrap();
        assert_eq!(content, "# 测试\n");
    }

    #[test]
    fn days_to_ymd_known_dates() {
        // 1970-01-01 = day 0
        assert_eq!(days_to_ymd(0), (1970, 1, 1));
        // 2000-01-01 = day 10957
        assert_eq!(days_to_ymd(10957), (2000, 1, 1));
        // 2026-09-09
        assert_eq!(days_to_ymd(20705), (2026, 9, 9));
    }

    // ── 任务 2.1：路径逃逸回归测试（Red） ──

    /// 辅助：构建包含有效 manifest + 必需文件 + 额外恶意条目的 ZIP。
    /// `extra_entries` 中的每个 (name, content) 会被追加到 ZIP。
    fn build_archive_with_extra_entries(zip_path: &Path, extra_entries: &[(&str, &[u8])]) {
        let file = fs::File::create(zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);

        // 有效 manifest
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(
            b"{\"version\": 1, \"timestamp\": \"\", \"device_name\": \"\", \"file_count\": 2}",
        )
        .unwrap();

        // 必需文件
        zip.start_file("hosts.toml", options).unwrap();
        zip.write_all(b"[[hosts]]\nid = \"h1\"\n").unwrap();
        zip.start_file("groups.toml", options).unwrap();
        zip.write_all(b"[[groups]]\nid = \"g1\"\n").unwrap();

        // 额外条目
        for (name, content) in extra_entries {
            zip.start_file(*name, options).unwrap();
            zip.write_all(*content).unwrap();
        }

        zip.finish().unwrap();
    }

    /// 将归档中唯一匹配的内容字节翻转，使其中央目录中的 CRC 与实际数据不一致。
    fn corrupt_archive_content(zip_path: &Path, original: &[u8]) {
        let mut bytes = fs::read(zip_path).unwrap();
        let offset = bytes
            .windows(original.len())
            .position(|window| window == original)
            .expect("归档应包含待损坏的存储条目内容");
        bytes[offset] ^= 0x01;
        fs::write(zip_path, bytes).unwrap();
    }

    /// 2.1 正常流程：仅含允许条目和非 ASCII snippet 的归档仍能导入。
    #[test]
    fn import_accepts_only_whitelisted_entries_with_non_ascii_snippet() {
        let dir = TempDir::new().unwrap();
        let zip_path = dir.path().join("valid.zip");
        build_archive_with_extra_entries(
            &zip_path,
            &[("snippets/笔记.md", b"# non-ascii snippet\n")],
        );

        let dst = TempDir::new().unwrap();
        let result = config_import(dst.path(), &zip_path);
        assert!(result.is_ok(), "合法归档应导入成功");
        assert!(dst.path().join("snippets/笔记.md").exists());
    }

    /// 2.1 意外操作：有效 manifest 与必需文件之后加入 `../` 路径逃逸条目。
    #[test]
    fn import_rejects_parent_directory_traversal() {
        let root = TempDir::new().unwrap();
        let sentinel = root.path().join("sentinel.txt");
        fs::write(&sentinel, "original").unwrap();

        let dst = root.path().join("config");
        let zip_path = root.path().join("evil.zip");
        build_archive_with_extra_entries(&zip_path, &[("../sentinel.txt", b"pwned\n")]);

        let err = config_import(&dst, &zip_path).unwrap_err();
        assert!(
            matches!(err, ImportError::UnsafeEntry(_)),
            "应返回 UnsafeEntry 错误，实际：{err:?}"
        );
        // 哨兵文件不应被修改
        assert_eq!(fs::read_to_string(&sentinel).unwrap(), "original");
        // 配置目录不应被创建或写入
        assert!(!dst.join("hosts.toml").exists());
    }

    /// 2.1 意外操作：绝对路径条目。
    #[test]
    fn import_rejects_absolute_path_entry() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("abs.zip");
        build_archive_with_extra_entries(&zip_path, &[("/etc/evil", b"pwned\n")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(
            matches!(err, ImportError::UnsafeEntry(_)),
            "应返回 UnsafeEntry 错误，实际：{err:?}"
        );
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.1 边界条件：恶意条目位于 ZIP 首位。
    #[test]
    fn import_rejects_malicious_entry_at_zip_start() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("first.zip");

        // 手动构建：恶意条目在 manifest 之前
        let file = fs::File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("../evil.txt", options).unwrap();
        zip.write_all(b"first").unwrap();
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(
            b"{\"version\": 1, \"timestamp\": \"\", \"device_name\": \"\", \"file_count\": 2}",
        )
        .unwrap();
        zip.start_file("hosts.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        zip.start_file("groups.toml", options).unwrap();
        zip.write_all(b"").unwrap();
        zip.finish().unwrap();

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(
            matches!(err, ImportError::UnsafeEntry(_)),
            "应返回 UnsafeEntry 错误，实际：{err:?}"
        );
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.1 边界条件：恶意条目位于 ZIP 末位（在合法条目之后）。
    #[test]
    fn import_rejects_malicious_entry_at_zip_end() {
        let root = TempDir::new().unwrap();
        let sentinel = root.path().join("sentinel_end.txt");
        fs::write(&sentinel, "original").unwrap();

        let dst = root.path().join("config");
        let zip_path = root.path().join("last.zip");
        build_archive_with_extra_entries(
            &zip_path,
            &[
                ("snippets/ok.md", b"# ok\n"),
                ("../../sentinel_end.txt", b"pwned\n"),
            ],
        );

        let err = config_import(&dst, &zip_path).unwrap_err();
        assert!(
            matches!(err, ImportError::UnsafeEntry(_)),
            "应返回 UnsafeEntry 错误，实际：{err:?}"
        );
        // 即使合法条目在前，哨兵文件也不应被修改
        assert_eq!(fs::read_to_string(&sentinel).unwrap(), "original");
        // 配置目录不应存在任何写入
        assert!(!dst.join("hosts.toml").exists());
        assert!(!dst.join("snippets/ok.md").exists());
    }

    /// 损坏的允许条目必须在备份和写入前被拒绝，不能留下部分导入。
    #[test]
    fn import_rejects_corrupt_payload_without_changing_existing_config() {
        let root = TempDir::new().unwrap();
        let zip_path = root.path().join("corrupt.zip");
        let corrupt_content = b"[[groups]]\nid = \"g1\"\n";
        build_archive_with_extra_entries(&zip_path, &[]);
        corrupt_archive_content(&zip_path, corrupt_content);

        let dst = root.path().join("config");
        fs::create_dir(&dst).unwrap();
        fs::write(dst.join("hosts.toml"), "old-hosts").unwrap();
        fs::write(dst.join("groups.toml"), "old-groups").unwrap();

        assert!(config_import(&dst, &zip_path).is_err());
        assert_eq!(
            fs::read_to_string(dst.join("hosts.toml")).unwrap(),
            "old-hosts"
        );
        assert_eq!(
            fs::read_to_string(dst.join("groups.toml")).unwrap(),
            "old-groups"
        );
    }

    /// 安全错误不得回显攻击者控制的归档条目名。
    #[test]
    fn unsafe_entry_error_hides_untrusted_entry_name() {
        let root = TempDir::new().unwrap();
        let zip_path = root.path().join("unsafe-name.zip");
        let marker = "攻击者控制的名称\\n伪造提示";
        let entry_name = format!("../{marker}");
        build_archive_with_extra_entries(&zip_path, &[(entry_name.as_str(), b"x")]);

        let err = config_import(&root.path().join("config"), &zip_path).unwrap_err();
        let message = err.to_string();
        assert_eq!(message, "unsafe archive entry");
        assert!(!message.contains(marker));
    }

    // ── 任务 2.2：白名单与边界测试（Red） ──

    /// 2.2 正常流程：可选 known_hosts 与多个不同 snippet。
    #[test]
    fn import_accepts_known_hosts_and_multiple_snippets() {
        let dir = TempDir::new().unwrap();
        let zip_path = dir.path().join("multi.zip");
        build_archive_with_extra_entries(
            &zip_path,
            &[
                ("known_hosts", b"example.com ssh-ed25519 AAAA\n"),
                ("snippets/a.md", b"# a\n"),
                ("snippets/b.md", b"# b\n"),
                ("snippets/中文.md", b"# zh snippet\n"),
            ],
        );

        let dst = TempDir::new().unwrap();
        let result = config_import(dst.path(), &zip_path).unwrap();
        assert_eq!(result.snippet_count, 3);
        assert!(dst.path().join("known_hosts").exists());
        assert!(dst.path().join("snippets/a.md").exists());
        assert!(dst.path().join("snippets/b.md").exists());
        assert!(dst.path().join("snippets/中文.md").exists());
    }

    /// 2.2 意外操作：根目录未知文件。
    #[test]
    fn import_rejects_unknown_root_file() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("unknown_root.zip");
        build_archive_with_extra_entries(&zip_path, &[("evil.toml", b"x")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.2 意外操作：目录条目（以 `/` 结尾的名称）。
    #[test]
    fn import_rejects_directory_entry() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("dir_entry.zip");
        build_archive_with_extra_entries(&zip_path, &[("snippets/", b"")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.2 意外操作：snippets 下额外层级。
    #[test]
    fn import_rejects_extra_levels_under_snippets() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("deep.zip");
        build_archive_with_extra_entries(&zip_path, &[("snippets/sub/deep.md", b"x")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.2 意外操作：平台歧义分隔符（反斜杠）。
    #[test]
    fn import_rejects_backslash_separator() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("backslash.zip");
        build_archive_with_extra_entries(&zip_path, &[("snippets\\evil.md", b"x")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
        assert!(!dst.path().join("hosts.toml").exists());
    }

    /// 2.2 边界条件：`.` 条目。
    #[test]
    fn import_rejects_dot_entry() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("dot.zip");
        build_archive_with_extra_entries(&zip_path, &[(".", b"")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
    }

    /// 2.2 边界条件：`..` 条目。
    #[test]
    fn import_rejects_dotdot_entry() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("dotdot.zip");
        build_archive_with_extra_entries(&zip_path, &[("..", b"")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
    }

    /// 2.2 边界条件：空 snippet 文件名（`snippets/` 已作为目录条目测试，此处测试空名）。
    #[test]
    fn import_rejects_empty_snippet_name() {
        let dst = TempDir::new().unwrap();
        let zip_path = dst.path().join("empty_snippet.zip");
        // snippets/ 本身是目录条目
        build_archive_with_extra_entries(&zip_path, &[("snippets/", b"")]);

        let err = config_import(dst.path(), &zip_path).unwrap_err();
        assert!(matches!(err, ImportError::UnsafeEntry(_)));
    }
}
