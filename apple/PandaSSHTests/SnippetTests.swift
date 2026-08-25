import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 代码片段测试：覆盖 Swift<->FFI 转换（正常/边界/意外操作）
/// 与 PandaCoreBackend 对 Rust SnippetStore 的持久化集成。
@MainActor
final class SnippetTests: XCTestCase {

    // MARK: - 转换层

    func testSnippetRoundTripPreservesFields() {
        let original = Snippet(
            id: "s-deploy",
            title: "Deploy release",
            tags: ["deploy", "git"],
            summary: "Deploy to prod.",
            code: "ssh deploy@prod 'git pull'"
        )

        let record = original.toSnippetRecord()
        let restored = Snippet(record: record)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.tags, original.tags)
        XCTAssertEqual(restored.summary, original.summary)
        XCTAssertEqual(restored.code, original.code)
    }

    func testSnippetRoundTripWithEmptySummary() {
        let original = Snippet(id: "s-only-code", title: "Only code", tags: [], summary: "", code: "ls -la")
        let record = original.toSnippetRecord()
        let restored = Snippet(record: record)

        XCTAssertEqual(restored.summary, "")
        XCTAssertEqual(restored.code, "ls -la")
    }

    func testSnippetParseFallsBackToBodyWhenMarkersMissing() {
        // 意外操作：来自旧格式或手工编辑的 body 没有标记，整体作为 code 保留。
        let record = SnippetRecord(name: "s-legacy", title: "Legacy", tags: [], body: "plain body without markers")
        let snippet = Snippet(record: record)

        XCTAssertEqual(snippet.summary, "")
        XCTAssertEqual(snippet.code, "plain body without markers")
    }

    func testSnippetParseStripsCodeBlockFence() {
        let body = """
        ## 说明
        Some note.

        ## 代码
        ```bash
        echo hello
        ```
        """
        let record = SnippetRecord(name: "s-fenced", title: "Fenced", tags: [], body: body)
        let snippet = Snippet(record: record)

        XCTAssertEqual(snippet.summary, "Some note.")
        XCTAssertEqual(snippet.code, "echo hello")
    }

    // MARK: - Backend 集成

    func testBackendSnippetCRUD() {
        let backend = makeBackend()

        let snippet = Snippet(id: "s-new", title: "New snippet", tags: ["test"], summary: "Note", code: "ls")
        backend.saveSnippet(snippet)
        XCTAssertEqual(backend.allSnippets().count, 1)
        XCTAssertEqual(backend.allSnippets().first?.title, "New snippet")

        var updated = snippet
        updated.title = "Updated"
        backend.saveSnippet(updated)
        XCTAssertEqual(backend.allSnippets().count, 1)
        XCTAssertEqual(backend.allSnippets().first?.title, "Updated")

        backend.deleteSnippet(id: "s-new")
        XCTAssertTrue(backend.allSnippets().isEmpty)
    }

    func testBackendDeleteUnknownSnippetIsNoOp() {
        let backend = makeBackend()
        backend.deleteSnippet(id: "ghost")
        XCTAssertTrue(backend.allSnippets().isEmpty)
    }

    private func makeBackend() -> PandaCoreBackend {
        // 复用 config 目录，避免测试间污染。
        let backend = PandaCoreBackend()
        _ = backend.allHosts()
        return backend
    }
}
