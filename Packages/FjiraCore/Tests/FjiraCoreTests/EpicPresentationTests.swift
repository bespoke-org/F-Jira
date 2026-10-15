import Foundation
import XCTest
@testable import FjiraCore

private let epicJSON = #"{"id":999,"key":"EX-99","name":"Platform & tools","summary":"Long epic issue summary","color":{"key":"color_2"}}"#

final class EpicPresentationTests: XCTestCase {
    func testAgileEpicUsesDisplayNameAndColorAndSurvivesSerialization() throws {
        let issue = try task(epic: epicJSON)
        let restored = try JSONDecoder().decode(JiraIssue.self, from: JSONEncoder().encode(issue))
        XCTAssertEqual(restored.epicLink?.id, "999")
        XCTAssertEqual(restored.epicLink?.displayName, "Platform & tools")
        XCTAssertEqual(restored.epicLink?.color?.key, "color_2")
        XCTAssertEqual(restored.hasEpicLinkField, true)
        let detailData = Data("{\"id\":\"100\",\"key\":\"EX-1\",\"fields\":{\"epic\":\(epicJSON)}}".utf8)
        let snapshot = CachedIssueDetail(issue: try JSONDecoder().decode(JiraIssueDetail.self, from: detailData),
            response: detailData, fetchedAt: Date(), generation: UUID(), commentPages: [], previousComments: [])
        let html = IssueBodyHTML.document(detail: snapshot, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertTrue(html.contains("<span>Platform &amp; tools</span></a>"))
        XCTAssertTrue(html.contains("href=\"fjira://epic/EX-99\""))
        XCTAssertTrue(html.contains("background: #fff1e0"))
        XCTAssertFalse(html.contains("<span>EX-99</span>"))
    }

    func testPartialSearchPreservesEpicButExplicitRemovalAndReassignmentDoNot() throws {
        let original = try task(epic: epicJSON)
        let partial = try task(epic: nil)
        XCTAssertEqual(original.accepting(partial).epicLink?.displayName, "Platform & tools")
        let removed = try task(epic: "null")
        XCTAssertNil(original.accepting(removed).epicLink)
        let reassigned = try task(epic: #"{"key":"EX-88"}"#)
        XCTAssertEqual(original.accepting(reassigned).epicLink?.displayName, "EX-88")
        XCTAssertNil(original.accepting(reassigned).epicLink?.color)
    }

    func testLegacyBoardSnapshotRecoversExpandedEpicFromRawResponse() throws {
        let response = Data("{\"startAt\":0,\"maxResults\":50,\"total\":1,\"issues\":[{\"id\":\"100\",\"key\":\"EX-1\",\"fields\":{\"epic\":\(epicJSON)}}]}".utf8)
        let page = CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: response), response: response, fetchedAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        var oldPage = try XCTUnwrap(object["page"] as? [String: Any])
        var issues = try XCTUnwrap(oldPage["issues"] as? [[String: Any]])
        issues[0].removeValue(forKey: "epicLink")
        issues[0].removeValue(forKey: "hasEpicLinkField")
        oldPage["issues"] = issues
        object["page"] = oldPage
        let restored = try JSONDecoder().decode(CachedIssuePage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.page.issues.first?.epicLink?.displayName, "Platform & tools")
        XCTAssertEqual(restored.page.issues.first?.epicLink?.color?.key, "color_2")
    }

    func testBoardMetadataIsSharedWithOtherIssueDetailsAfterRestartAndIsAccountScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        _ = try await cache.reconcileIssues([task(epic: epicJSON)], site: "site", account: "alice")
        let response = Data(#"{"id":"200","key":"EX-2","fields":{"customfield_42":"EX-99"},"names":{"customfield_42":"Epic Link"}}"#.utf8)
        let detail = CachedIssueDetail(issue: try JSONDecoder().decode(JiraIssueDetail.self, from: response),
            response: response, fetchedAt: Date(), generation: UUID(), commentPages: [], previousComments: [])
        try await cache.saveIssue(detail, site: "site", account: "alice")
        let reopened = try ConnectionCache(path: path)
        let saved = try await reopened.loadIssue(site: "site", account: "alice", id: "200")
        XCTAssertEqual(saved?.issue.epicLink?.displayName, "Platform & tools")
        XCTAssertEqual(saved?.issue.epicLink?.color?.key, "color_2")
        let other = try await reopened.loadEpic(site: "site", account: "bob", key: "EX-99")
        XCTAssertNil(other)
    }

    func testConcurrentRequestsShareOneEpicFetchAndKeepCredentialsIsolated() async throws {
        let transport = EpicPresentationTransport()
        let client = JiraClient(transport: transport)
        let site = try JiraSite("https://jira.example.com/jira")
        async let first = client.epic(site: site, token: "alice", key: "EX-99")
        async let second = client.epic(site: site, token: "alice", key: "EX-99")
        let values = try await [first, second]
        XCTAssertEqual(values.map { $0.epic.displayName }, ["Platform & tools", "Platform & tools"])
        _ = try await client.epic(site: site, token: "alice", key: "EX-99")
        let initial = await transport.requests
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.url?.path, "/jira/rest/agile/1.0/epic/EX-99")
        _ = try await client.epic(site: site, token: "bob", key: "EX-99")
        let isolated = await transport.requests
        XCTAssertEqual(isolated.count, 2)
    }

    @MainActor
    func testReaderLoadsEpicNameThenRestoresItOffline() async throws {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: EpicPresentationTransport()), token: { "alice" })
        reader.open(try task(epic: nil))
        await reader.currentTask?.value
        await reader.epicTask?.value
        XCTAssertEqual(reader.detail?.issue.epicLink?.displayName, "Platform & tools")
        reader.close()
        let offline = IssueReader(site: site, account: "alice", cache: cache,
                                  client: JiraClient(transport: EpicPresentationTransport(offline: true)), token: { "alice" })
        offline.open(try task(epic: nil))
        await offline.currentTask?.value
        XCTAssertEqual(offline.detail?.issue.epicLink?.displayName, "Platform & tools")
        XCTAssertEqual(offline.detail?.issue.epicLink?.color?.key, "color_2")
        XCTAssertTrue(offline.isOffline)
        offline.close()
    }

    private func task(epic: String?) throws -> JiraIssue {
        let fields = epic.map { "\"epic\":\($0)" } ?? ""
        return try JSONDecoder().decode(JiraIssue.self, from: Data("{\"id\":\"100\",\"key\":\"EX-1\",\"fields\":{\(fields)}}".utf8))
    }
}

private actor EpicPresentationTransport: JiraTransport {
    var requests: [URLRequest] = []
    let offline: Bool
    init(offline: Bool = false) { self.offline = offline }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let body: String
        if request.url?.path.contains("/epic/") == true {
            try await Task.sleep(for: .milliseconds(20))
            body = epicJSON
        } else if request.url?.lastPathComponent == "remotelink" {
            body = "[]"
        } else {
            body = #"{"id":"100","key":"EX-1","fields":{"summary":"Task","customfield_42":"EX-99"},"names":{"customfield_42":"Epic Link"}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
