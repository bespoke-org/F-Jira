import Foundation
import GRDB
import XCTest
@testable import FjiraCore

private let taskWithEpic = #"{"id":"100","key":"EX-1","fields":{"summary":"Task","customfield_54321":"EX-99","comment":{"startAt":0,"maxResults":1,"total":2,"comments":[{"id":"c1","body":"First"}]}},"names":{"customfield_54321":"Epic Link"}}"#
private let epicIssue = #"{"id":"999","key":"EX-99","fields":{"summary":"Epic summary","issuetype":{"name":"Epic"}}}"#

final class EpicLinkTests: XCTestCase {
    func testSchemaIdentifiesLocalizedEpicFieldAndTakesPrecedenceOverNames() throws {
        let json = #"{"id":"100","key":"EX-1","fields":{"customfield_77777":"EX-99","customfield_11111":"WRONG-1"},"names":{"customfield_77777":"Связь с эпиком","customfield_11111":"Epic Link"},"schema":{"customfield_77777":{"custom":"com.pyxis.greenhopper.jira:gh-epic-link"},"customfield_11111":{"custom":"other:string"}}}"#
        let issue = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(json.utf8))
        XCTAssertEqual(issue.epicLink?.key, "EX-99")
        let snapshot = CachedIssueDetail(issue: issue, response: Data(json.utf8), fetchedAt: Date(),
                                         generation: UUID(), commentPages: [], previousComments: [])
        let html = IssueBodyHTML.document(detail: snapshot, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertTrue(html.contains("<dt>Epic Link</dt><dd><a href=\"fjira://epic/EX-99\">EX-99</a></dd>"))
    }

    func testNamesFallbackAndExpandedEpicReference() throws {
        let task = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(taskWithEpic.utf8))
        XCTAssertEqual(task.epicLink?.key, "EX-99")
        XCTAssertEqual(task.epicLink?.listIssue.id, "EX-99")
        let object = #"{"id":"100","key":"EX-1","fields":{"customfield_22222":{"id":"999","key":"EX-99","fields":{"summary":"Epic & summary"}}},"names":{"customfield_22222":"Epic Link"}}"#
        let expanded = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(object.utf8))
        XCTAssertEqual(expanded.epicLink?.id, "999")
        XCTAssertEqual(expanded.epicLink?.summary, "Epic & summary")
        let restored = try JSONDecoder().decode(JiraIssueDetail.self, from: JSONEncoder().encode(expanded))
        XCTAssertEqual(restored.epicLink?.summary, "Epic & summary")
    }

    func testAbsentNullAndInvalidEpicValuesDoNotBreakIssueDecoding() throws {
        for value in ["null", "123", #""../myself""#, #""javascript:alert(1)""#, #"{"key":"bad"}"#] {
            let json = "{\"id\":\"100\",\"key\":\"EX-1\",\"fields\":{\"customfield_42\":\(value)},\"names\":{\"customfield_42\":\"Epic Link\"}}"
            let issue = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(json.utf8))
            XCTAssertNil(issue.epicLink, value)
        }
        XCTAssertNil(try JSONDecoder().decode(JiraIssueDetail.self, from: Data(epicIssue.utf8)).epicLink)
    }

    func testOldSnapshotsRecoverEpicWithoutLosingPagesOrGeneration() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try ConnectionCache(path: path)
        var detail = try await JiraClient(transport: StubTransport([(200, taskWithEpic)]))
            .issue(site: JiraSite("https://jira.example.com"), token: "fixture-token", id: "100")
        let pageData = Data(#"{"startAt":1,"maxResults":1,"total":2,"comments":[{"id":"c2","body":"Second"}]}"#.utf8)
        detail.commentPages = [CachedCommentPage(page: try JSONDecoder().decode(CommentPage.self, from: pageData),
                                                response: pageData, fetchedAt: Date())]
        detail.remoteLinks = CachedRemoteIssueLinks(links: [], response: Data("[]".utf8), fetchedAt: Date())
        try await cache.saveIssue(detail, site: "site", account: "alice")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        var projection = try XCTUnwrap(old["issue"] as? [String: Any])
        projection.removeValue(forKey: "epicLink")
        old["issue"] = projection
        let payload = try JSONSerialization.data(withJSONObject: old)
        let database = try DatabaseQueue(path: path)
        try await database.write { db in
            try db.execute(sql: "UPDATE response_cache SET payload = ? WHERE site = ? AND account = ? AND resource = ?",
                           arguments: [payload, "site", "alice", "issue-detail:100"])
        }
        let reopened = try ConnectionCache(path: path)
        let saved = try await reopened.loadIssue(site: "site", account: "alice", id: "100")
        XCTAssertEqual(saved?.issue.epicLink?.key, "EX-99")
        XCTAssertEqual(saved?.generation, detail.generation)
        XCTAssertEqual(saved?.fetchedAt.timeIntervalSince1970, detail.fetchedAt.timeIntervalSince1970)
        XCTAssertEqual(saved?.comments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(saved?.remoteLinks?.response, detail.remoteLinks?.response)
    }

    @MainActor
    func testOpenEpicResolvesIssueKeyToCanonicalIDAndReusesCachedDetailsOffline() async throws {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let client = JiraClient(transport: EpicTransport())
        let task = try await client.issue(site: site, token: "fixture-token", id: "100")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "fixture-token" })
        reader.open(task.issue.listIssue)
        await reader.currentTask?.value
        reader.openEpic()
        await reader.currentTask?.value
        XCTAssertEqual(reader.detail?.issue.id, "999")
        XCTAssertEqual(reader.selection?.id, "999")
        XCTAssertEqual(reader.detail?.issue.key, "EX-99")
        reader.close()

        let offline = IssueReader(site: site, account: "alice", cache: cache,
                                  client: JiraClient(transport: EpicTransport(offline: true)), token: { "fixture-token" })
        offline.open(task.issue.listIssue)
        await offline.currentTask?.value
        offline.openEpic()
        await offline.currentTask?.value
        XCTAssertEqual(offline.detail?.issue.id, "999")
        XCTAssertEqual(offline.selection?.id, "999")
        XCTAssertTrue(offline.isOffline)
        offline.open(task.issue.listIssue)
        offline.openEpic()
        XCTAssertEqual(offline.detail?.issue.id, "999", "Reopening a viewed epic must use the in-memory snapshot immediately")
        offline.close()
        let other = try await cache.loadIssue(site: site.identifier, account: "bob", id: "EX-99")
        XCTAssertNil(other)
    }

    @MainActor
    func testEpicNavigationRejectsAResponseForAnotherIssueKey() async throws {
        let site = try JiraSite("https://jira.example.com")
        let task = try await JiraClient(transport: EpicTransport()).issue(site: site, token: "fixture-token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(task, site: site.identifier, account: "alice")
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: EpicTransport(wrongEpic: true)), token: { "fixture-token" })
        reader.open(task.issue.listIssue)
        await reader.currentTask?.value
        reader.openEpic()
        await reader.currentTask?.value
        XCTAssertNil(reader.detail)
        XCTAssertNotNil(reader.errorMessage)
        reader.close()
    }

    func testRefreshingAnIssueClearsARemovedEpicLink() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: StubTransport([(200, taskWithEpic), (200, #"{"id":"100","key":"EX-1","fields":{"summary":"Task","customfield_54321":null},"names":{"customfield_54321":"Epic Link"}}"#)]))
        try await cache.saveIssue(client.issue(site: site, token: "fixture-token", id: "100"), site: site.identifier, account: "alice")
        try await cache.saveIssue(client.issue(site: site, token: "fixture-token", id: "100"), site: site.identifier, account: "alice")
        let saved = try await cache.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertNil(saved?.issue.epicLink)
    }
}

private actor EpicTransport: JiraTransport {
    let offline: Bool
    let wrongEpic: Bool
    init(offline: Bool = false, wrongEpic: Bool = false) { self.offline = offline; self.wrongEpic = wrongEpic }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if offline { throw URLError(.notConnectedToInternet) }
        let data: String
        switch request.url?.lastPathComponent {
        case "remotelink": data = "[]"
        case "100": data = taskWithEpic
        default: data = wrongEpic ? epicIssue.replacingOccurrences(of: "EX-99", with: "OTHER-99") : epicIssue
        }
        return (Data(data.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
