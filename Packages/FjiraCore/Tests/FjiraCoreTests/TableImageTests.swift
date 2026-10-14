import Foundation
import GRDB
import XCTest
@testable import FjiraCore

private let tableTypeURL = URL(string: "https://jira.example.com/type.svg")!
private let tablePriorityURL = URL(string: "https://jira.example.com/priority.svg")!
private let tablePersonURL = URL(string: "https://jira.example.com/avatar/person.png")!
private let tablePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGLsAAAAASUVORK5CYII=")!

final class TableImageTests: XCTestCase {
    func testTableImagesIncludeSharedAssigneeAndPriorityWithMetadataFirst() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let query = try ProjectQuery(projectID: "10000", input: "")
        let page = try fixture()
        try await cache.savePage(page, site: "site", account: "alice", query: query)
        for url in [tableTypeURL, tablePriorityURL, tablePersonURL] {
            try await cache.saveAvatar(CachedAvatar(data: tablePNG, mimeType: "image/png", fetchedAt: Date()),
                                       site: "site", account: "alice", url: url)
        }
        let result = try await cache.loadSearchPresentation(site: "site", account: "alice", query: query)
        XCTAssertEqual(result?.search.tableImageURLs, [tableTypeURL, tablePriorityURL, tablePersonURL],
                       "Type and priority icons must precede profile images, with each URL included only once")
        XCTAssertEqual(result?.images.count, 3)
        XCTAssertEqual(result?.images[tablePersonURL.absoluteString]?.data, tablePNG)
        XCTAssertEqual(result?.images[tablePriorityURL.absoluteString]?.data, tablePNG)
        XCTAssertEqual(result?.search.issues.map(\.assignee), ["Alice", "Alice", "Unassigned"])
    }

    func testOlderSearchRecoversAvatarAndPriorityURLsFromItsRawResponse() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let query = try ProjectQuery(projectID: "10000", input: "")
        let page = try fixture()
        try await cache.savePage(page, site: "site", account: "alice", query: query)
        for url in [tablePriorityURL, tablePersonURL] {
            try await cache.saveAvatar(CachedAvatar(data: tablePNG, mimeType: "image/png", fetchedAt: Date()),
                                       site: "site", account: "alice", url: url)
        }
        let original = try await cache.loadSearch(site: "site", account: "alice", query: query)
        let saved = try XCTUnwrap(original)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var pages = try XCTUnwrap(old["pages"] as? [[String: Any]])
        var projection = try XCTUnwrap(pages[0]["page"] as? [String: Any])
        var issues = try XCTUnwrap(projection["issues"] as? [[String: Any]])
        for index in issues.indices {
            var fields = try XCTUnwrap(issues[index]["fields"] as? [String: Any])
            var priority = try XCTUnwrap(fields["priority"] as? [String: Any])
            priority.removeValue(forKey: "iconUrl")
            fields["priority"] = priority
            if var assignee = fields["assignee"] as? [String: Any] {
                assignee.removeValue(forKey: "avatarUrls")
                fields["assignee"] = assignee
            }
            issues[index]["fields"] = fields
        }
        projection["issues"] = issues
        pages[0]["page"] = projection
        old["pages"] = pages
        let data = try JSONSerialization.data(withJSONObject: old)
        let database = await cache.database
        try await database.write { db in
            try db.execute(sql: "UPDATE search_snapshot SET snapshot = ? WHERE site = ? AND account = ? AND project = ? AND input = ?",
                           arguments: [data, "site", "alice", query.projectID, query.input])
        }
        let result = try await cache.loadSearchPresentation(site: "site", account: "alice", query: query)
        XCTAssertEqual(result?.search.tableImageURLs, [tableTypeURL, tablePriorityURL, tablePersonURL])
        XCTAssertEqual(result?.images[tablePersonURL.absoluteString]?.data, tablePNG)
        XCTAssertEqual(result?.images[tablePriorityURL.absoluteString]?.data, tablePNG)
        XCTAssertEqual(result?.search.generation, saved.generation)
        XCTAssertEqual(result?.search.fetchedAt.timeIntervalSince1970, saved.fetchedAt.timeIntervalSince1970)
    }

    private func fixture() throws -> CachedIssuePage {
        let issues: [[String: Any]] = (0..<3).map { index in
            let assignee: Any = index < 2
                ? ["name": "alice", "displayName": "Alice", "avatarUrls": ["48x48": tablePersonURL.absoluteString]] as [String: Any]
                : NSNull()
            let fields: [String: Any] = [
                "summary": "Fixture", "status": ["name": "Open", "statusCategory": ["key": "new"]],
                "issuetype": ["name": "Task", "iconUrl": tableTypeURL.absoluteString],
                "priority": ["name": "High", "iconUrl": tablePriorityURL.absoluteString],
                "assignee": assignee
            ]
            return ["id": String(100 + index), "key": "EX-\(index + 1)", "fields": fields]
        }
        let data = try JSONSerialization.data(withJSONObject: ["startAt": 0, "maxResults": 50, "total": 3, "issues": issues])
        return CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: data), response: data, fetchedAt: Date())
    }
}
