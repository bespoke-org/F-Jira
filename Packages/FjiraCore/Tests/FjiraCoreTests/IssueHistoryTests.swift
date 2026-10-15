import Foundation
import XCTest
@testable import FjiraCore

final class IssueHistoryTests: XCTestCase {
    func testServerHistoryRequestAndChronologicalOrder() async throws {
        let transport = HistoryTransport()
        let history = try await JiraClient(transport: transport).issueHistory(
            site: JiraSite("https://jira.example.com/jira"), token: "token", id: "100")
        XCTAssertEqual(history.newestFirst.map(\.id), ["2", "1"])
        XCTAssertEqual(history.entries.first?.items.first?.fromString, "New")
        XCTAssertEqual(history.total, 2)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/jira/rest/api/2/issue/100")
        XCTAssertEqual(request.httpMethod, "GET")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "expand" }?.value, "changelog")
        XCTAssertEqual(items?.first { $0.name == "fields" }?.value, "summary")
        XCTAssertTrue(String(decoding: history.response, as: UTF8.self).contains("histories"))
    }

    func testHistorySurvivesCacheReopeningAndRefreshButRejectsOldGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: HistoryTransport())
        let first = try await client.issue(site: site, token: "token", id: "100")
        let history = try await client.issueHistory(site: site, token: "token", id: "100")
        try await cache.saveIssue(first, site: site.identifier, account: "alice")
        try await cache.saveIssueHistory(history, site: site.identifier, account: "alice", id: "100", expectedGeneration: first.generation)
        let reopened = try ConnectionCache(path: path)
        let restored = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(restored?.history?.response, history.response)
        let other = try await reopened.loadIssue(site: site.identifier, account: "bob", id: "100")
        XCTAssertNil(other)
        let fresh = try await client.issue(site: site, token: "token", id: "100")
        try await reopened.saveIssue(fresh, site: site.identifier, account: "alice")
        let refreshed = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(refreshed?.history?.entries.count, 2)
        do {
            try await reopened.saveIssueHistory(history, site: site.identifier, account: "alice", id: "100", expectedGeneration: first.generation)
            XCTFail("Late history must not replace a refreshed snapshot")
        } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        old.removeValue(forKey: "history")
        XCTAssertNil(try JSONDecoder().decode(CachedIssueDetail.self, from: JSONSerialization.data(withJSONObject: old)).history)
    }

    @MainActor
    func testReaderLoadsOnDemandAndKeepsHistoryAfterOfflineRefresh() async throws {
        let transport = HistoryTransport()
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: transport)
        let cache = try ConnectionCache(path: ":memory:")
        let issue = try await client.issue(site: site, token: "token", id: "100")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "token" })
        defer { reader.close() }
        reader.open(issue.issue.listIssue)
        await reader.currentTask?.value
        XCTAssertNil(reader.detail?.history)
        var requests = await transport.historyRequests
        XCTAssertEqual(requests, 0)
        reader.selectActivity(.history)
        await reader.historyTask?.value
        XCTAssertEqual(reader.detail?.history?.entries.count, 2)
        reader.selectActivity(.comments)
        reader.selectActivity(.history)
        requests = await transport.historyRequests
        XCTAssertEqual(requests, 1, "Switching tabs must reuse the downloaded history")
        await transport.setOffline()
        reader.refresh()
        await reader.currentTask?.value
        await reader.historyTask?.value
        XCTAssertEqual(reader.detail?.history?.entries.count, 2)
        XCTAssertNotNil(reader.historyError)
        reader.close()
        reader.open(issue.issue.listIssue)
        XCTAssertEqual(reader.detail?.history?.entries.count, 2, "A reopened issue must show history synchronously from memory")
        await reader.currentTask?.value
        await reader.historyTask?.value
    }

    @MainActor
    func testLateHistoryCannotReplaceAnotherIssue() async throws {
        let transport = HistoryTransport(holdHistory: true)
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: transport)
        let reader = IssueReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"), client: client, token: { "token" })
        let first = try await client.issue(site: site, token: "token", id: "100")
        let second = try await client.issue(site: site, token: "token", id: "200")
        reader.open(first.issue.listIssue)
        await reader.currentTask?.value
        reader.selectActivity(.history)
        let task = reader.historyTask
        for _ in 0..<100 {
            if await transport.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await transport.isWaiting
        XCTAssertTrue(waiting)
        reader.selectActivity(.comments)
        reader.open(second.issue.listIssue)
        await reader.currentTask?.value
        await transport.releaseHistory()
        await task?.value
        XCTAssertEqual(reader.detail?.issue.id, "200")
        XCTAssertNil(reader.detail?.history)
        reader.close()
    }

    func testHistoryMarkupEscapesValuesAndRendersOnlySelectedTab() async throws {
        let client = JiraClient(transport: HistoryTransport())
        let site = try JiraSite("https://jira.example.com")
        var detail = try await client.issue(site: site, token: "token", id: "100")
        detail.history = try await client.issueHistory(site: site, token: "token", id: "100")
        let comments = IssueBodyHTML.document(detail: detail, baseURL: site.url, dark: false)
        XCTAssertTrue(comments.contains("Comment body"))
        XCTAssertFalse(comments.contains("<article class=\"history-entry\">"))
        let history = IssueBodyHTML.document(detail: detail, baseURL: site.url, dark: true, activityTab: .history, historyLimit: 1)
        XCTAssertTrue(history.contains("aria-selected=\"true\" aria-controls=\"activity-panel\" href=\"fjira://activity/history"))
        XCTAssertTrue(history.contains("&lt;script&gt;new&lt;/script&gt;"))
        XCTAssertFalse(history.contains("<script>new</script>"))
        XCTAssertFalse(history.contains("GRDB."), "HTML interpolation must not select SQL interpolation overloads")
        XCTAssertFalse(history.contains("Comment body"))
        XCTAssertTrue(history.contains("Show more changes"))
        XCTAssertTrue(history.contains("Alice &amp; Bob"))
        XCTAssertFalse(history.contains("Showing history downloaded"))
        let failed = IssueBodyHTML.document(detail: detail, baseURL: site.url, dark: false, activityTab: .history, historyError: "Offline")
        XCTAssertTrue(failed.contains("Showing history downloaded"))
        XCTAssertTrue(failed.contains("Retry"))
    }
}

private actor HistoryTransport: JiraTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var historyRequests = 0
    private var offline = false
    private var holdHistory: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    init(holdHistory: Bool = false) { self.holdHistory = holdHistory }
    func setOffline() { offline = true }
    func releaseHistory() { holdHistory = false; continuation?.resume(); continuation = nil }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let history = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "expand" && $0.value == "changelog" } == true
        if history {
            historyRequests += 1
            if holdHistory { await withCheckedContinuation { continuation = $0 } }
        }
        if offline { throw URLError(.notConnectedToInternet) }
        let id = url.lastPathComponent
        let body: String
        if id == "remotelink" { body = "[]" }
        else if history {
            body = """
            {"id":"\(id)","key":"EX-\(id)","changelog":{"startAt":0,"maxResults":2,"total":2,"histories":[
            {"id":"1","created":"2026-10-15T12:00:00.000+0400","author":{"displayName":"Alice & Bob"},"items":[{"field":"status","fromString":"New","toString":"Review"}]},
            {"id":"2","created":"2026-10-15T10:00:00.000+0000","author":{"displayName":"Alice & Bob"},"items":[{"field":"description","fromString":null,"toString":"<script>new</script>"}]}]}}
            """
        } else {
            body = """
            {"id":"\(id)","key":"EX-\(id)","fields":{"summary":"Example","comment":{"comments":[{"id":"c1","body":"Comment body"}]}}}
            """
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
