import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 侧栏搜索过滤测试:正常流程(按名称/地址/用户名匹配)、
/// 分组匹配(分组名命中时显示其下主机)、边界条件(空查询、
/// 空白查询、大小写、无匹配)。
final class HostSearchTests: XCTestCase {

    private let backend = MockBackend.demo()
    private var hosts: [HostEntry] { backend.allHosts() }
    private var groups: [HostGroup] { backend.allGroups() }

    private func search(_ query: String) -> [HostEntry] {
        HostSearch.filter(hosts: hosts, groups: groups, query: query)
    }

    // MARK: - 正常流程

    func testMatchByName() {
        let hits = search("web-prod")
        XCTAssertEqual(hits.map(\.id), ["h-webprod"])
    }

    func testMatchByAddress() {
        let hits = search("203.0.113")
        XCTAssertEqual(Set(hits.map(\.id)), ["h-webprod", "h-webbackup"])
    }

    func testMatchByUsername() {
        let hits = search("deploy")
        XCTAssertEqual(hits.map(\.id), ["h-staging"])
    }

    func testMatchIsCaseInsensitive() {
        let hits = search("WEB-PROD")
        XCTAssertEqual(hits.map(\.id), ["h-webprod"])
    }

    // MARK: - 分组匹配:分组名命中时显示其下主机

    func testGroupNameMatchShowsHostsUnderIt() {
        let hits = search("华东")
        XCTAssertEqual(Set(hits.map(\.id)), ["h-webprod", "h-webbackup"])
    }

    func testParentGroupMatchIncludesSubgroupHosts() {
        // 「生产环境」命中时,其子分组「华东」内的主机也一并显示
        let hits = search("生产")
        XCTAssertTrue(Set(["h-webprod", "h-webbackup", "h-legacy"]).isSubset(of: Set(hits.map(\.id))))
    }

    // MARK: - 边界条件

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(search("").count, hosts.count)
    }

    func testWhitespaceOnlyQueryReturnsAll() {
        XCTAssertEqual(search("   ").count, hosts.count)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(search("不存在的主机xyz").isEmpty)
    }

    func testEmptyHostListReturnsEmpty() {
        XCTAssertTrue(HostSearch.filter(hosts: [], groups: [], query: "a").isEmpty)
    }
}
