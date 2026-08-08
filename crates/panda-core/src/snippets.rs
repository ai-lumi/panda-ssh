//! Code snippet storage: each snippet is a Markdown file with YAML frontmatter.
//!
//! File format:
//! ```markdown
//! ---
//! title: Deploy release
//! tags: [deploy, git]
//! ---
//! ## 说明
//! ...
//! ## 代码
//! ```bash
//! ssh deploy@prod ...
//! ```
//! ```

use std::fs;
use std::path::PathBuf;

/// A single code snippet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snippet {
    /// File name without the `.md` extension. Stable identifier.
    pub name: String,
    /// Display title; falls back to `name` when missing or malformed.
    pub title: String,
    /// Tags for lightweight grouping.
    pub tags: Vec<String>,
    /// Markdown body (description + code blocks).
    pub body: String,
}

impl Snippet {
    /// Serialize to Markdown file content.
    pub fn to_markdown(&self) -> String {
        let tags = if self.tags.is_empty() {
            "[]".to_string()
        } else {
            format!(
                "[{}]",
                self.tags
                    .iter()
                    .map(|t| format!("\"{}\"", t))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        format!(
            "---\ntitle: \"{}\"\ntags: {}\n---\n{}",
            escape_yaml_string(&self.title),
            tags,
            self.body
        )
    }
}

/// File-system backed snippet store.
#[derive(Clone)]
pub struct SnippetStore {
    dir: PathBuf,
}

impl SnippetStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// Scan the directory for `.md` files and parse them. Invalid files are
    /// skipped rather than surfaced as errors.
    pub fn list(&self) -> crate::Result<Vec<Snippet>> {
        let mut snippets = Vec::new();
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(snippets),
            Err(e) => return Err(e.into()),
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                if let Ok(text) = fs::read_to_string(&path) {
                    if let Some(snippet) = parse_snippet(name, &text) {
                        snippets.push(snippet);
                    }
                }
            }
        }
        snippets.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(snippets)
    }

    /// Write a snippet to disk atomically (temp file + rename).
    pub fn save(&self, snippet: &Snippet) -> crate::Result<()> {
        fs::create_dir_all(&self.dir)?;
        let path = self.dir.join(format!("{}.md", snippet.name));
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, snippet.to_markdown())?;
        fs::rename(&tmp, &path)?;
        Ok(())
    }

    /// Delete a snippet file by name. Missing file is a no-op.
    pub fn delete(&self, name: &str) -> crate::Result<()> {
        let path = self.dir.join(format!("{}.md", name));
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

/// Parse frontmatter and body from Markdown text.
fn parse_snippet(name: &str, text: &str) -> Option<Snippet> {
    let (frontmatter, body) = split_frontmatter(text)?;
    let mut title = name.to_string();
    let mut tags = Vec::new();
    for line in frontmatter.lines() {
        let line = line.trim();
        if let Some(value) = line.strip_prefix("title:") {
            title = parse_yaml_string(value)
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| name.to_string());
        } else if let Some(value) = line.strip_prefix("tags:") {
            tags = parse_yaml_array(value);
        }
    }
    Some(Snippet {
        name: name.to_string(),
        title,
        tags,
        body: body.to_string(),
    })
}

/// Split text into frontmatter text (without delimiters) and body.
fn split_frontmatter(text: &str) -> Option<(&str, &str)> {
    let text = text.trim_start();
    if !text.starts_with("---") {
        return Some(("", text));
    }
    let rest = &text[3..];
    if let Some(end) = rest.find("\n---") {
        let fm = &rest[..end];
        let body = &rest[end + 4..];
        Some((fm, body.trim_start()))
    } else {
        None
    }
}

fn parse_yaml_string(value: &str) -> Option<String> {
    let value = value.trim();
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        Some(unescape_yaml_string(&value[1..value.len() - 1]))
    } else if value.len() >= 2 && value.starts_with('\'') && value.ends_with('\'') {
        Some(value[1..value.len() - 1].to_string())
    } else {
        Some(value.to_string())
    }
}

fn unescape_yaml_string(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => result.push('\n'),
                Some('t') => result.push('\t'),
                Some('"') => result.push('"'),
                Some('\\') => result.push('\\'),
                Some(other) => {
                    result.push('\\');
                    result.push(other);
                }
                None => result.push('\\'),
            }
        } else {
            result.push(c);
        }
    }
    result
}

fn escape_yaml_string(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\t', "\\t")
}

fn parse_yaml_array(value: &str) -> Vec<String> {
    let value = value.trim();
    if value.len() < 2 || !value.starts_with('[') || !value.ends_with(']') {
        return Vec::new();
    }
    let inner = &value[1..value.len() - 1];
    if inner.trim().is_empty() {
        return Vec::new();
    }
    inner
        .split(',')
        .filter_map(|item| {
            let item = item.trim();
            if item.is_empty() {
                None
            } else {
                parse_yaml_string(item)
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn sample_markdown() -> &'static str {
        "---\ntitle: \"Deploy release\"\ntags: [deploy, git]\n---\n## 说明\nDeploy to prod.\n\n## 代码\n```bash\nssh deploy@prod 'git pull'\n```\n"
    }

    #[test]
    fn parse_valid_snippet() {
        let snippet = parse_snippet("deploy", sample_markdown()).unwrap();
        assert_eq!(snippet.name, "deploy");
        assert_eq!(snippet.title, "Deploy release");
        assert_eq!(snippet.tags, vec!["deploy", "git"]);
        assert!(snippet.body.contains("Deploy to prod."));
        assert!(snippet.body.contains("ssh deploy@prod"));
    }

    #[test]
    fn parse_missing_frontmatter_uses_filename() {
        let text = "## 说明\nJust body.";
        let snippet = parse_snippet("fallback", text).unwrap();
        assert_eq!(snippet.title, "fallback");
        assert!(snippet.tags.is_empty());
        assert!(snippet.body.contains("Just body."));
    }

    #[test]
    fn parse_malformed_frontmatter_falls_back_gracefully() {
        let text = "---\nthis is not yaml\n---\nbody";
        let snippet = parse_snippet("bad", text).unwrap();
        assert_eq!(snippet.title, "bad");
        assert_eq!(snippet.body, "body");
    }

    #[test]
    fn round_trip_preserves_content() {
        let original = parse_snippet("rt", sample_markdown()).unwrap();
        let text = original.to_markdown();
        let parsed = parse_snippet("rt", &text).unwrap();
        assert_eq!(original.title, parsed.title);
        assert_eq!(original.tags, parsed.tags);
        assert_eq!(original.body, parsed.body);
    }

    #[test]
    fn list_skips_invalid_files() {
        let dir = tempfile::tempdir().unwrap();
        let store = SnippetStore::new(dir.path().to_path_buf());
        write_file(dir.path().join("valid.md"), sample_markdown());
        write_file(dir.path().join("broken.md"), "---\nunclosed frontmatter");
        write_file(dir.path().join("not-md.txt"), "---\ntitle: x\n---\n");

        let list = store.list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "valid");
    }

    #[test]
    fn save_and_delete_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let store = SnippetStore::new(dir.path().to_path_buf());
        let snippet = Snippet {
            name: "save-test".into(),
            title: "Save Test".into(),
            tags: vec!["t1".into()],
            body: "body".into(),
        };
        store.save(&snippet).unwrap();
        let list = store.list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0], snippet);

        store.delete("save-test").unwrap();
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn delete_missing_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let store = SnippetStore::new(dir.path().to_path_buf());
        store.delete("missing").unwrap();
    }

    #[test]
    fn list_returns_empty_for_missing_dir() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("does-not-exist");
        let store = SnippetStore::new(missing);
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn empty_tags_serializes_as_empty_array() {
        let snippet = Snippet {
            name: "empty-tags".into(),
            title: "Title".into(),
            tags: vec![],
            body: "body".into(),
        };
        let md = snippet.to_markdown();
        assert!(md.contains("tags: []"));
    }

    #[test]
    fn parse_single_quoted_title_and_yaml_escapes() {
        let text = "---\ntitle: 'Say \"hello\"'\ntags: [a, b]\n---\nbody";
        let snippet = parse_snippet("quoted", text).unwrap();
        assert_eq!(snippet.title, "Say \"hello\"");
        assert_eq!(snippet.tags, vec!["a", "b"]);
    }

    #[test]
    fn parse_title_fallback_when_value_is_malformed() {
        // title: 后面只有空白,无法解析,回退到文件名。
        let text = "---\ntitle:   \ntags: []\n---\nbody";
        let snippet = parse_snippet("fallback", text).unwrap();
        assert_eq!(snippet.title, "fallback");
    }

    #[test]
    fn save_creates_parent_directory() {
        let dir = tempfile::tempdir().unwrap();
        let store = SnippetStore::new(dir.path().join("nested").join("snippets"));
        let snippet = Snippet {
            name: "deep".into(),
            title: "Deep".into(),
            tags: vec![],
            body: "body".into(),
        };
        store.save(&snippet).unwrap();
        assert!(!store.list().unwrap().is_empty());
    }

    fn write_file(path: PathBuf, content: &str) {
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
    }
}
