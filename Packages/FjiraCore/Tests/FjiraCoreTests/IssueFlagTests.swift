import Foundation
import XCTest
@testable import FjiraCore

final class IssueFlagTests: XCTestCase {
    private let names = #""names":{"customfield_98765":"Flagged","customfield_12":"Remote Feature Flag"}"#
    private let selected = #"[{"id":"10304","value":"Impediment"}]"#

    func testCustomFieldDecodingDistinguishesClearedMissingAndUnrelatedFlags() throws {
        for (value, expected) in [(selected, true), ("[]", false), ("null", false)] {
            let json = issueJSON(fields: "\"customfield_98765\":\(value),\"customfield_12\":\(selected)", names: names)
            let detail = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(json.utf8))
            XCTAssertEqual(detail.flagged, expected)
            XCTAssertEqual(detail.listIssue.isFlagged, expected)
            let restored = try JSONDecoder().decode(JiraIssueDetail.self, from: JSONEncoder().encode(detail))
            XCTAssertEqual(restored.flagged, expected)
        }
        let missing = issueJSON(fields: "\"customfield_12\":\(selected)", names: names)
        XCTAssertNil(try JSONDecoder().decode(JiraIssueDetail.self, from: Data(missing.utf8)).flagged)
        let malformed = issueJSON(fields: #""customfield_98765":"invalid""#, names: names)
        XCTAssertNil(try JSONDecoder().decode(JiraIssueDetail.self, from: Data(malformed.utf8)).flagged)
    }

    func testAgileBooleanAndSearchPageMetadataSurviveEncoding() throws {
        for value in [true, false] {
            let raw = issueJSON(fields: "\"flagged\":\(value)")
            let issue = try JSONDecoder().decode(JiraIssue.self, from: Data(raw.utf8))
            XCTAssertEqual(issue.flagged, value)
            XCTAssertEqual(try JSONDecoder().decode(JiraIssue.self, from: JSONEncoder().encode(issue)).flagged, value)
        }
        let page = try JSONDecoder().decode(IssuePage.self, from: pageData())
        XCTAssertTrue(try XCTUnwrap(page.issues.first).isFlagged)
        let restored = try JSONDecoder().decode(IssuePage.self, from: JSONEncoder().encode(page))
        XCTAssertTrue(try XCTUnwrap(restored.issues.first).isFlagged)
    }

    func testSearchDiscoversFieldOnceAndRequestsItByID() async throws {
        let json = String(decoding: pageData(), as: UTF8.self)
        let catalog = #"[{"id":"customfield_98765","name":"Flagged"},{"id":"customfield_12","name":"Remote Feature Flag"}]"#
        let transport = StubTransport([(200, json), (200, json), (200, json)], fieldResponse: catalog)
        let client = JiraClient(transport: transport)
        let site = try JiraSite("https://jira.example.com")
        let query = try ProjectQuery(projectID: "10000", input: "")
        for token in ["alice", "alice", "bob"] {
            let page = try await client.search(site: site, token: token, query: query)
            XCTAssertTrue(try XCTUnwrap(page.page.issues.first).isFlagged)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "field" }.count, 2,
                       "Reuse discovery within an account, but isolate different credentials")
        for request in requests.filter({ $0.url?.lastPathComponent == "search" }) {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let fields = try XCTUnwrap(body["fields"] as? [String])
            XCTAssertTrue(fields.contains("customfield_98765"))
            XCTAssertFalse(fields.contains("customfield_12"))
            XCTAssertEqual(body["expand"] as? [String], ["names"])
        }
    }

    func testDirectVerificationIncludesFlagField() async throws {
        let json = issueJSON(fields: "\"customfield_98765\":\(selected)", names: names)
        let transport = StubTransport([(200, json)], fieldResponse: #"[{"id":"customfield_98765","name":"Flagged"}]"#)
        let issue = try await JiraClient(transport: transport).issueSummary(
            site: JiraSite("https://jira.example.com"), token: "token", id: "100")
        XCTAssertTrue(issue.isFlagged)
        let requests = await transport.capturedRequests()
        let url = try XCTUnwrap(requests.last?.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.first { $0.name == "fields" }?.value?.contains("customfield_98765") == true)
        XCTAssertEqual(items.first { $0.name == "expand" }?.value, "names")
    }

    func testOldBoardPageRecoversFlagFromRawResponseWithoutChangingOtherFields() throws {
        let raw = Data("{\"startAt\":0,\"maxResults\":50,\"total\":1,\"issues\":[\(issueJSON(fields: #""flagged":true"#))]}".utf8)
        let original = try JSONDecoder().decode(IssuePage.self, from: raw)
        var old = original.issues[0]
        old.flagged = nil
        let page = IssuePage(startAt: 0, maxResults: 50, total: 1, issues: [old], warningMessages: nil)
        let snapshot = CachedIssuePage(page: page, response: raw, fetchedAt: Date())
        let restored = try JSONDecoder().decode(CachedIssuePage.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(try XCTUnwrap(restored.page.issues.first).isFlagged)
        XCTAssertEqual(restored.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(restored.response, raw)
    }

    func testFlagCacheSurvivesReopeningAndClearingPropagatesToDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let query = try ProjectQuery(projectID: "10000", input: "")
        let raw = Data(issueJSON(fields: "\"customfield_98765\":\(selected)", names: names).utf8)
        var detail = try JSONDecoder().decode(JiraIssueDetail.self, from: raw)
        // Simulate a detail saved before flag support existed.
        detail.flagged = nil
        try await cache.saveIssue(CachedIssueDetail(issue: detail, response: raw, fetchedAt: Date(),
            generation: UUID(), commentPages: [], previousComments: []), site: "site", account: "alice")
        let page = try JSONDecoder().decode(IssuePage.self, from: pageData())
        try await cache.savePage(CachedIssuePage(page: page, response: pageData(), fetchedAt: Date()),
                                 site: "site", account: "alice", query: query)
        let reopened = try ConnectionCache(path: path)
        let restored = try await reopened.loadIssue(site: "site", account: "alice", id: "100")
        let search = try await reopened.loadSearch(site: "site", account: "alice", query: query)
        XCTAssertEqual(restored?.issue.flagged, true)
        XCTAssertEqual(search?.issues.first?.flagged, true)
        let clearedJSON = issueJSON(fields: #""flagged":false"#, updated: "2026-10-15T12:00:00.000+0000")
        let cleared = try JSONDecoder().decode(JiraIssue.self, from: Data(clearedJSON.utf8))
        _ = try await reopened.reconcileIssues([cleared], site: "site", account: "alice")
        let unflagged = try await reopened.loadIssue(site: "site", account: "alice", id: "100")
        let unflaggedSearch = try await reopened.loadSearch(site: "site", account: "alice", query: query)
        XCTAssertEqual(unflagged?.issue.flagged, false)
        XCTAssertEqual(unflaggedSearch?.issues.first?.flagged, false)
        XCTAssertFalse(cleared.accepting(page.issues[0]).isFlagged, "An older flagged response must not undo clearing")
        let unknown = try JSONDecoder().decode(JiraIssue.self, from: Data(issueJSON(fields: #""summary":"partial""#).utf8))
        XCTAssertTrue(page.issues[0].accepting(unknown).isFlagged, "An omitted field must not clear a known flag")
    }

    private func issueJSON(fields: String, names: String? = nil, updated: String = "2026-10-14T12:00:00.000+0000") -> String {
        "{\"id\":\"100\",\"key\":\"EX-1\",\"fields\":{\"updated\":\"\(updated)\",\(fields)}\(names.map { "," + $0 } ?? "")}"
    }

    private func pageData() -> Data {
        Data("{\"startAt\":0,\"maxResults\":50,\"total\":1,\(names),\"issues\":[\(issueJSON(fields: "\"customfield_98765\":\(selected)"))]}".utf8)
    }
}
