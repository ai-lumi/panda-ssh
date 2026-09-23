use panda_ffi::{delete_snippet, init_store, list_snippets, save_snippet, SnippetRecord};

#[test]
fn snippet_lifecycle_and_edge_cases() {
    let dir = std::env::temp_dir().join(format!("panda-ffi-snippets-{}", uuid::Uuid::new_v4()));
    let _ = std::fs::remove_dir_all(&dir);
    init_store(dir.to_string_lossy().into_owned()).unwrap();

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

    let _ = std::fs::remove_dir_all(&dir);
}
