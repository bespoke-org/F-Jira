import AppKit
import Foundation
import GRDB
import XCTest
@testable import FjiraCore

private let typeIcon = URL(string: "https://jira.example.com/icons/task.svg")!
private let epicIcon = URL(string: "https://jira.example.com/icons/epic.svg")!
private let typeSVG = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="#2684ff" d="M2 2h12v12H2z"/></svg>"##.utf8)
private let iconPage = #"{"startAt":0,"maxResults":50,"total":3,"issues":[{"id":"100","key":"EX-1","fields":{"summary":"First task","status":{"name":"Open","statusCategory":{"key":"new"}},"issuetype":{"name":"Task","iconUrl":"https://jira.example.com/icons/task.svg"}}},{"id":"101","key":"EX-2","fields":{"summary":"Second task","status":{"name":"Open","statusCategory":{"key":"new"}},"issuetype":{"name":"Task","iconUrl":"https://jira.example.com/icons/task.svg"}}},{"id":"102","key":"EX-3","fields":{"summary":"Epic","status":{"name":"Open","statusCategory":{"key":"new"}},"issuetype":{"name":"Epic","iconUrl":"https://jira.example.com/icons/epic.svg"}}}]}"#

final class IssueTypeIconTests: XCTestCase {
    func testSearchRestoresUniqueTypeImagesWithItsRows() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let query = try ProjectQuery(projectID: "10000", input: "")
        let page = CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: Data(iconPage.utf8)),
                                   response: Data(iconPage.utf8), fetchedAt: Date())
        try await cache.savePage(page, site: "site", account: "alice", query: query)
        for url in [typeIcon, epicIcon] {
            try await cache.saveAvatar(CachedAvatar(data: typeSVG, mimeType: "image/svg+xml", fetchedAt: Date()),
                                       site: "site", account: "alice", url: url)
        }
        let presentation = try await cache.loadSearchPresentation(site: "site", account: "alice", query: query)
        XCTAssertEqual(presentation?.search.issueTypeIconURLs, [typeIcon, epicIcon])
        XCTAssertEqual(presentation?.search.issues.count, 3)
        XCTAssertEqual(presentation?.images.count, 2, "Repeated task types must share the same cached image")
        XCTAssertEqual(presentation?.images[typeIcon.absoluteString]?.data, typeSVG)
        let image = try XCTUnwrap(NSImage(data: XCTUnwrap(presentation?.images[typeIcon.absoluteString]?.data)))
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), "SVG icons must render in native table cells")
        let other = try await cache.loadSearchPresentation(site: "site", account: "bob", query: query)
        XCTAssertNil(other)
    }

    func testLegacySearchRecoversMissingIconsEvenWhenStatusCategoriesArePresent() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let query = try ProjectQuery(projectID: "10000", input: "")
        let page = CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: Data(iconPage.utf8)),
                                   response: Data(iconPage.utf8), fetchedAt: Date())
        try await cache.savePage(page, site: "site", account: "alice", query: query)
        try await cache.saveAvatar(CachedAvatar(data: typeSVG, mimeType: "image/svg+xml", fetchedAt: Date()),
                                   site: "site", account: "alice", url: typeIcon)
        let original = try await cache.loadSearch(site: "site", account: "alice", query: query)
        let snapshot = try XCTUnwrap(original)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var pages = try XCTUnwrap(old["pages"] as? [[String: Any]])
        var projection = try XCTUnwrap(pages[0]["page"] as? [String: Any])
        var issues = try XCTUnwrap(projection["issues"] as? [[String: Any]])
        for index in issues.indices {
            var fields = try XCTUnwrap(issues[index]["fields"] as? [String: Any])
            var type = try XCTUnwrap(fields["issuetype"] as? [String: Any])
            type.removeValue(forKey: "iconUrl")
            fields["issuetype"] = type
            issues[index]["fields"] = fields
        }
        projection["issues"] = issues
        pages[0]["page"] = projection
        old["pages"] = pages
        let payload = try JSONSerialization.data(withJSONObject: old)
        let database = await cache.database
        try await database.write { db in
            try db.execute(sql: "UPDATE search_snapshot SET snapshot = ? WHERE site = ? AND account = ? AND project = ? AND input = ?",
                           arguments: [payload, "site", "alice", query.projectID, query.input])
        }
        let restored = try await cache.loadSearchPresentation(site: "site", account: "alice", query: query)
        XCTAssertEqual(restored?.search.issueTypeIconURLs, [typeIcon, epicIcon])
        XCTAssertEqual(restored?.images[typeIcon.absoluteString]?.data, typeSVG)
        XCTAssertEqual(restored?.search.generation, snapshot.generation)
        XCTAssertEqual(restored?.search.fetchedAt.timeIntervalSince1970, snapshot.fetchedAt.timeIntervalSince1970)
        XCTAssertEqual(restored?.search.issues.map(\.key), snapshot.issues.map(\.key))
    }

    @MainActor
    func testPreloadedTableIconIsImmediatelyReusedWhenOpeningIssue() async throws {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let json = #"{"id":"100","key":"EX-1","fields":{"summary":"Task","issuetype":{"name":"Task","iconUrl":"https://jira.example.com/icons/task.svg"}}}"#
        let issue = try await JiraClient(transport: StubTransport([(200, json)])).issue(site: site, token: "fixture-token", id: "100")
        try await cache.saveIssue(issue, site: site.identifier, account: "alice")
        let transport = TableIconOfflineTransport()
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: transport), token: { "fixture-token" })
        reader.reuseImages([typeIcon.absoluteString: CachedAvatar(data: typeSVG, mimeType: "image/svg+xml", fetchedAt: Date())])
        reader.open(issue.issue.listIssue)
        XCTAssertEqual(reader.avatars[typeIcon.absoluteString]?.data, typeSVG, "Opening an issue must reuse its table icon immediately")
        await reader.currentTask?.value
        await reader.avatarTask?.value
        XCTAssertEqual(reader.avatars[typeIcon.absoluteString]?.data, typeSVG)
        let requests = await transport.count
        XCTAssertEqual(requests, 1, "The already loaded type icon must not be downloaded again")
        reader.close()
    }
}

private actor TableIconOfflineTransport: JiraTransport {
    private(set) var count = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        throw URLError(.notConnectedToInternet)
    }
}
