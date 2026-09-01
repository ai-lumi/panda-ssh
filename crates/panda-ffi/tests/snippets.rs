use std::io::Write;

use panda_ffi::{delete_snippet, init_snippets, list_snippets, save_snippet, SnippetRecord};

#[test]
fn snippet_lifecycle_and_edge_cases() {
    // 1. 未初始化时接口报错。
    assert!(list_snippets().is_err());
    assert!(save_snippet(SnippetRecord {
        name: "x".into(),
        title: "X".into(),
        tags: vec![],
        body: "body".into(),
    })
    .is_err());
    assert!(delete_snippet("x".into()).is_err());

    // 2. CRUD 正常流程。
    let dir = std::env::temp_dir().join(format!("panda-ffi-snippets-{}", uuid::Uuid::new_v4()));
    let _ = std::fs::remove_dir_all(&dir);
    init_snippets(dir.to_string_lossy().into_owned()).unwrap();

    let snippet = SnippetRecord {
        name: "deploy".into(),
        title: "Deploy release".into(),
        tags: vec!["deploy".into(), "git".into()],
        body: "ssh deploy@prod 'git pull'".into(),
    };
    save_snippet(snippet.clone()).unwrap();

    let list = list_snippets().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0], snippet);

    let updated = SnippetRecord {
        title: "Deploy release v2".into(),
        ..snippet
    };
    save_snippet(updated.clone()).unwrap();
    let list = list_snippets().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].title, "Deploy release v2");

    delete_snippet("deploy".into()).unwrap();
    assert!(list_snippets().unwrap().is_empty());

    // 3. 损坏文件被跳过。
    let dir2 = std::env::temp_dir().join(format!("panda-ffi-snippets-{}", uuid::Uuid::new_v4()));
    let _ = std::fs::remove_dir_all(&dir2);
    std::fs::create_dir_all(&dir2).unwrap();

    let mut valid = std::fs::File::create(dir2.join("valid.md")).unwrap();
    valid
        .write_all(b"---\ntitle: \"OK\"\ntags: []\n---\nbody")
        .unwrap();

    let mut broken = std::fs::File::create(dir2.join("broken.md")).unwrap();
    broken.write_all(b"---\nunclosed frontmatter").unwrap();

    init_snippets(dir2.to_string_lossy().into_owned()).unwrap();

    let list = list_snippets().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "valid");

    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&dir2);
}
