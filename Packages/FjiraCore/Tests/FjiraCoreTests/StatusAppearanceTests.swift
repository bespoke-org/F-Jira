import Foundation
import XCTest
@testable import FjiraCore

final class StatusAppearanceTests: XCTestCase {
    func testStatusToneUsesCategoryWithoutGuessingWorkflowNames() throws {
        for (category, color, expected) in [
            ("new", "green", JiraStatusTone.neutral),
            ("indeterminate", "yellow", .inProgress),
            ("in-flight", "yellow", .inProgress),
            ("done", "green", .done),
            ("completed", "green", .done),
            ("custom", "yellow", .inProgress),
            ("custom", "green", .done),
            ("custom", "unknown", .neutral)
        ] {
            let issue = try decodeIssue(category: category, color: color)
            XCTAssertEqual(issue.listIssue.status, "QA & Review")
            XCTAssertEqual(issue.listIssue.statusTone, expected)
        }
        let missing = try JSONDecoder().decode(JiraIssue.self, from: Data(#"{"id":"100","key":"EX-1","fields":{"status":{"name":"Done"}}}"#.utf8))
        XCTAssertEqual(missing.statusTone, .neutral, "A workflow name alone must not imply a category")
    }

    func testPillKeepsStatusTextAndUsesMatchingLightAndDarkPalettes() throws {
        let issue = try decodeIssue(category: "indeterminate", color: "yellow")
        let detail = CachedIssueDetail(issue: issue, response: Data(), fetchedAt: Date(), generation: UUID(), commentPages: [], previousComments: [])
        for dark in [false, true] {
            let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com")!, dark: dark)
            let palette = JiraStatusTone.inProgress.palette(dark: dark)
            XCTAssertTrue(html.contains("class=\"status-pill status-in-progress\""))
            XCTAssertTrue(html.contains("<span>QA &amp; Review</span>"))
            XCTAssertTrue(html.contains("color: \(palette.foregroundCSS); background: \(palette.backgroundCSS)"))
        }
    }

    func testOlderSearchAndDetailSnapshotsRecoverCategoriesWithoutNetwork() async throws {
        let issue = try decodeIssue(category: "indeterminate", color: "yellow")
        let rawIssue = try JSONEncoder().encode(issue)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: rawIssue) as? [String: Any])
        var fields = try XCTUnwrap(oldObject["fields"] as? [String: Any])
        var status = try XCTUnwrap(fields["status"] as? [String: Any])
        status.removeValue(forKey: "statusCategory")
        fields["status"] = status
        oldObject["fields"] = fields
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let oldIssue = try JSONDecoder().decode(JiraIssueDetail.self, from: oldData)
        XCTAssertEqual(oldIssue.listIssue.statusTone, .neutral)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let generation = UUID()
        let legacy = CachedIssueDetail(issue: oldIssue, response: rawIssue, fetchedAt: date, generation: generation, commentPages: [], previousComments: [])
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(legacy, site: "site", account: "alice")
        let restored = try await cache.loadIssue(site: "site", account: "alice", id: issue.id)
        XCTAssertEqual(restored?.issue.listIssue.statusTone, .inProgress)
        XCTAssertEqual(restored?.generation, generation)
        XCTAssertEqual(restored?.fetchedAt, date)

        let rawPage = try JSONSerialization.data(withJSONObject: ["startAt": 0, "maxResults": 50, "total": 1,
            "issues": [try JSONSerialization.jsonObject(with: rawIssue)]])
        let oldPage = try JSONSerialization.data(withJSONObject: ["startAt": 0, "maxResults": 50, "total": 1,
            "issues": [oldObject]])
        let page = CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: oldPage), response: rawPage, fetchedAt: date)
        let query = try ProjectQuery(projectID: "10000", input: "")
        try await cache.savePage(page, site: "site", account: "alice", query: query)
        let search = try await cache.loadSearch(site: "site", account: "alice", query: query)
        XCTAssertEqual(search?.issues.first?.statusTone, .inProgress)
        XCTAssertEqual(search?.issues.map(\.key), ["EX-1"])
        XCTAssertEqual(search?.fetchedAt, date)
        XCTAssertEqual(search?.total, 1)
        let history = try await cache.recentSearches(site: "site", account: "alice", project: "10000")
        XCTAssertEqual(history.first?.issues.first?.statusTone, .inProgress)
        let otherAccount = try await cache.loadSearch(site: "site", account: "bob", query: query)
        XCTAssertNil(otherAccount)
    }

    private func decodeIssue(category: String, color: String) throws -> JiraIssueDetail {
        let data = try JSONSerialization.data(withJSONObject: ["id": "100", "key": "EX-1", "fields": [
            "summary": "Status fixture", "status": ["name": "QA & Review", "statusCategory": ["key": category, "colorName": color]]
        ]])
        return try JSONDecoder().decode(JiraIssueDetail.self, from: data)
    }
}
