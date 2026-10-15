import Foundation
import XCTest
@testable import FjiraCore

@MainActor
final class IssueNavigationTests: XCTestCase {
    func testEpicNavigationReusesCachedDetailsAndPreservesCanonicalHistoryOffline() async throws {
        let (reader, first, _) = try await fixture()
        defer { reader.resetNavigation() }
        reader.open(first)
        await reader.currentTask?.value
        reader.openEpic()
        await reader.currentTask?.value
        XCTAssertEqual(reader.selection?.id, "2")
        XCTAssertTrue(reader.canGoBack)
        reader.goBack()
        XCTAssertEqual(reader.selection?.id, "1")
        XCTAssertEqual(reader.detail?.issue.id, "1", "Back must show the cached body immediately")
        XCTAssertTrue(reader.canGoForward)
        reader.goForward()
        XCTAssertEqual(reader.selection?.id, "2")
        XCTAssertEqual(reader.detail?.issue.id, "2", "Forward must reuse the same cached body")
        await reader.currentTask?.value
        XCTAssertTrue(reader.isOffline)
        reader.goBack()
        reader.goBack()
        XCTAssertNil(reader.selection)
        XCTAssertFalse(reader.canGoBack)
        reader.goForward()
        XCTAssertEqual(reader.selection?.id, "1")
    }

    func testClosingIssueCanBeUndoneAndNewSelectionClearsForwardBranch() async throws {
        let (reader, first, second) = try await fixture()
        defer { reader.resetNavigation() }
        reader.open(first)
        await reader.currentTask?.value
        reader.open(second)
        await reader.currentTask?.value
        reader.close()
        XCTAssertNil(reader.selection)
        reader.goBack()
        XCTAssertEqual(reader.detail?.issue.id, "2")
        reader.goBack()
        XCTAssertEqual(reader.detail?.issue.id, "1")
        reader.refresh()
        XCTAssertTrue(reader.canGoForward, "Refreshing must not discard the forward branch")
        reader.open(first)
        XCTAssertTrue(reader.canGoForward, "Re-selecting the current issue must not add a visit")
        let third = try JSONDecoder().decode(JiraIssue.self,
            from: Data(#"{"id":"3","key":"EX-3","fields":{"summary":"Third"}}"#.utf8))
        reader.open(third)
        XCTAssertFalse(reader.canGoForward)
        reader.goBack()
        XCTAssertEqual(reader.detail?.issue.id, "1")
        reader.resetNavigation()
        XCTAssertNil(reader.selection)
        XCTAssertFalse(reader.canGoBack)
        XCTAssertFalse(reader.canGoForward)
    }

    func testHistoryCanNavigateWhileRequestsAreStillLoading() async throws {
        let (reader, first, second) = try await fixture()
        defer { reader.resetNavigation() }
        reader.open(first)
        reader.open(second)
        reader.goBack()
        await reader.currentTask?.value
        XCTAssertEqual(reader.selection?.id, "1")
        XCTAssertEqual(reader.detail?.issue.id, "1")
        reader.goForward()
        await reader.currentTask?.value
        XCTAssertEqual(reader.selection?.id, "2")
        XCTAssertEqual(reader.detail?.issue.id, "2")
    }

    func testVisitsTrackOpeningAndNavigationButNotRefreshes() async throws {
        let (reader, first, second) = try await fixture()
        defer { reader.resetNavigation() }
        var visits: [String] = []
        reader.onVisit = { visits.append($0.key) }
        reader.open(first)
        await reader.currentTask?.value
        reader.refresh()
        await reader.currentTask?.value
        XCTAssertEqual(visits, [first.key])
        reader.open(second)
        reader.goBack()
        XCTAssertEqual(visits, [first.key, second.key, first.key])
    }

    private func fixture() async throws -> (IssueReader, JiraIssue, JiraIssue) {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let client = JiraClient(transport: NavigationFixtureTransport())
        let first = try await client.issue(site: site, token: "fixture-token", id: "1")
        let second = try await client.issue(site: site, token: "fixture-token", id: "2")
        try await cache.saveIssue(first, site: site.identifier, account: "fixture")
        try await cache.saveIssue(second, site: site.identifier, account: "fixture")
        let reader = IssueReader(site: site, account: "fixture", cache: cache,
                                 client: JiraClient(transport: NavigationFixtureTransport(offline: true)),
                                 token: { "fixture-token" })
        return (reader, first.issue.listIssue, second.issue.listIssue)
    }
}

private struct NavigationFixtureTransport: JiraTransport {
    var offline = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if offline { throw URLError(.notConnectedToInternet) }
        let id = request.url?.lastPathComponent == "1" ? "1" : "2"
        let data = Data("""
            {"id":"\(id)","key":"EX-\(id)","fields":{"summary":"Fixture \(id)",
            "description":"Body \(id)","customfield_10001":"EX-2"},
            "names":{"customfield_10001":"Epic Link"}}
            """.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
