import Foundation
import XCTest
@testable import FjiraCore

private let issueJSON = #"""
{
  "id":"100", "key":"EX-1",
  "fields": {
    "summary":"Example issue", "description":"Wiki description", "status":{"name":"Open","id":"1"},
    "assignee":null, "reporter":{"name":"alice","displayName":"Alice"}, "priority":null,
    "issuetype":{"name":"Task"}, "labels":["backend"], "customfield_10000":"retained",
    "comment":{"startAt":0,"maxResults":1,"total":2,"comments":[{"id":"c1","body":"First comment","author":{"displayName":"Alice"}}]},
    "subtasks":[{"id":"101","key":"EX-2","fields":{"summary":"Subtask"}}],
    "issuelinks":[{"id":"link1","type":{"name":"Blocks","outward":"blocks","inward":"is blocked by"},"outwardIssue":{"id":"102","key":"EX-3","fields":{"summary":"Linked issue"}}}],
    "attachment":[{"id":"a1","filename":"example.txt","size":123,"content":"https://jira.example.com/attachment/1"}]
  },
  "renderedFields":{"description":"<p>A <strong>formatted</strong> description.</p>","comment":{"comments":[{"id":"c1","body":"<p>Formatted comment</p>"}]}}
}
"""#

private let secondCommentJSON = #"{"startAt":1,"maxResults":1,"total":2,"comments":[{"id":"c2","body":"Second comment","renderedBody":"<p>Second formatted comment</p>"}]}"#

final class IssueDetailTests: XCTestCase {
    func testRequestsFullIssueWithRenderedFieldsAndDecodesRelations() async throws {
        let transport = StubTransport([(200, issueJSON)])
        let detail = try await JiraClient(transport: transport).issue(site: JiraSite("https://jira.example.com/jira"), token: "token", id: "100")
        XCTAssertEqual(detail.issue.listIssue.assignee, "Unassigned")
        XCTAssertEqual(detail.issue.fields.subtasks?.first?.key, "EX-2")
        XCTAssertEqual(detail.issue.fields.issuelinks?.first?.label, "blocks")
        XCTAssertEqual(detail.issue.fields.attachment?.first?.filename, "example.txt")
        XCTAssertEqual(detail.renderedBody(for: detail.comments[0]), "<p>Formatted comment</p>")
        XCTAssertTrue(detail.hasMoreComments)
        XCTAssertTrue(String(decoding: detail.response, as: UTF8.self).contains("customfield_10000"))
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/jira/rest/api/2/issue/100")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "expand" }?.value, "renderedFields,names")
        XCTAssertNil(request.httpBody)
    }

    func testRejectsIssuePathTraversalBeforeSendingCredentials() async throws {
        let transport = StubTransport([])
        do {
            _ = try await JiraClient(transport: transport).issue(site: JiraSite("https://jira.example.com"), token: "token", id: "../myself")
            XCTFail("Expected invalid identifier")
        } catch { XCTAssertEqual(error as? JiraError, .invalidResponse) }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDetailAndCommentPagesSurviveRestartAndAreIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let site = try JiraSite("https://jira.example.com/jira")
        let transport = StubTransport([(200, issueJSON), (200, secondCommentJSON)])
        let client = JiraClient(transport: transport)
        let detail = try await client.issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(detail, site: site.identifier, account: "alice")
        let page = try await client.comments(site: site, token: "token", id: "100", startAt: detail.nextCommentStartAt)
        try await cache.saveComments(page, site: site.identifier, account: "alice", id: "100", expectedGeneration: detail.generation)
        let reopened = try ConnectionCache(path: path)
        let loaded = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.comments.map(\.id), ["c1", "c2"])
        XCTAssertFalse(restored.hasMoreComments)
        XCTAssertEqual(restored.response, detail.response)
        XCTAssertEqual(restored.commentPages.first?.response, page.response)
        let otherAccount = try await reopened.loadIssue(site: site.identifier, account: "bob", id: "100")
        let otherSite = try await reopened.loadIssue(site: "other", account: "alice", id: "100")
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherSite)
        let requests = await transport.capturedRequests()
        let request = requests[1]
        let params = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(params?.first { $0.name == "startAt" }?.value, "1")
        XCTAssertEqual(params?.first { $0.name == "expand" }?.value, "renderedBody")
    }

    func testPartialRefreshKeepsOlderCommentsButRejectsObsoletePagination() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: StubTransport([(200, issueJSON), (200, secondCommentJSON), (200, issueJSON)]))
        let first = try await client.issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(first, site: site.identifier, account: "alice")
        let page = try await client.comments(site: site, token: "token", id: "100", startAt: 1)
        try await cache.saveComments(page, site: site.identifier, account: "alice", id: "100", expectedGeneration: first.generation)
        let refreshed = try await client.issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(refreshed, site: site.identifier, account: "alice")
        let saved = try await cache.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(saved?.comments.map(\.id), ["c1", "c2"])
        XCTAssertTrue(saved?.hasPreviousComments == true)
        XCTAssertEqual(saved?.nextCommentStartAt, 1)
        do {
            try await cache.saveComments(page, site: site.identifier, account: "alice", id: "100", expectedGeneration: first.generation)
            XCTFail("Expected obsolete comment generation to fail")
        } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
    }

    @MainActor
    func testReaderDisplaysCachedDetailsAfterNetworkFailure() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let detail = try await JiraClient(transport: StubTransport([(200, issueJSON)])).issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(detail, site: site.identifier, account: "alice")
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: StubTransport([(503, "unavailable")])), token: { "token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        XCTAssertEqual(reader.detail?.issue.key, "EX-1")
        XCTAssertEqual(reader.detail?.fetchedAt, detail.fetchedAt)
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertFalse(reader.isOffline, "Server errors must not be presented as an offline connection")
        XCTAssertFalse(reader.isLoading)
    }

    @MainActor
    func testOfflineStateRequiresConnectivityFailureAndClearsAfterRecovery() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let cached = try await JiraClient(transport: StubTransport([(200, issueJSON)]))
            .issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(cached, site: site.identifier, account: "alice")
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .serverCertificateUntrusted] {
            let reader = IssueReader(site: site, account: "alice", cache: cache,
                                     client: JiraClient(transport: RecoveringIssueTransport(failure: code)), token: { "token" })
            reader.open(cached.issue.listIssue)
            XCTAssertFalse(reader.isOffline, "Opening a cached issue alone does not imply offline status")
            await reader.currentTask?.value
            XCTAssertEqual(reader.isOffline, code == .notConnectedToInternet || code == .networkConnectionLost)
            XCTAssertNotNil(reader.detail)
            XCTAssertNotNil(reader.errorMessage)
            reader.refresh()
            await reader.currentTask?.value
            XCTAssertFalse(reader.isOffline)
            XCTAssertNil(reader.errorMessage)
            reader.close()
        }
    }

    @MainActor
    func testReaderShowsCachedDetailsWhileNetworkRequestIsPending() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let cached = try await JiraClient(transport: StubTransport([(200, issueJSON)]))
            .issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(cached, site: site.identifier, account: "alice")
        let transport = DelayedIssueTransport()
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: transport), token: { "token" })
        reader.open(cached.issue.listIssue)
        let refresh = reader.currentTask
        await transport.waitForRequest("100")
        XCTAssertEqual(reader.detail?.issue.fields.description, "Wiki description")
        XCTAssertEqual(reader.detail?.fetchedAt, cached.fetchedAt)
        XCTAssertTrue(reader.isLoading)
        XCTAssertNil(reader.errorMessage)
        await transport.respond("100", body: issueJSON.replacingOccurrences(of: "Wiki description", with: "Fresh description"))
        await refresh?.value
        XCTAssertEqual(reader.detail?.issue.fields.description, "Fresh description")
        XCTAssertFalse(reader.isLoading)
    }

    @MainActor
    func testReopeningViewedIssueShowsDetailsSynchronously() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let issue = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(issueJSON.utf8)).listIssue
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: StubTransport([(200, issueJSON), (503, "offline"), (503, "offline")])),
                                 token: { "token" })
        reader.open(issue)
        await reader.currentTask?.value
        reader.close()
        reader.open(issue)
        XCTAssertEqual(reader.detail?.issue.key, "EX-1", "Reopening must show the last viewed state before any async work")
        XCTAssertEqual(reader.detail?.issue.fields.description, "Wiki description")
        await reader.currentTask?.value
        XCTAssertEqual(reader.detail?.issue.key, "EX-1")
        let unseen = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(issueJSON
            .replacingOccurrences(of: "\"id\":\"100\"", with: "\"id\":\"200\"").utf8)).listIssue
        reader.open(unseen)
        XCTAssertNil(reader.detail, "An unseen issue must not reuse another issue's details")
        await reader.currentTask?.value
    }

    @MainActor
    func testLateResponseCannotReplaceNewlySelectedIssue() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let first = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(issueJSON.utf8)).listIssue
        let secondJSON = issueJSON.replacingOccurrences(of: "\"id\":\"100\"", with: "\"id\":\"200\"")
            .replacingOccurrences(of: "\"key\":\"EX-1\"", with: "\"key\":\"EX-4\"")
        let second = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(secondJSON.utf8)).listIssue
        let transport = DelayedIssueTransport()
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport), token: { "token" })
        reader.open(first)
        let firstTask = reader.currentTask
        await transport.waitForRequest("100")
        reader.open(second)
        let secondTask = reader.currentTask
        await transport.waitForRequest("200")
        await transport.respond("200", body: secondJSON)
        await secondTask?.value
        await transport.respond("100", body: issueJSON)
        await firstTask?.value
        XCTAssertEqual(reader.selection?.id, "200")
        XCTAssertEqual(reader.detail?.issue.id, "200")
        reader.close()
        XCTAssertNil(reader.selection)
        XCTAssertNil(reader.detail)
    }

    func testHTMLPreservesFormattingAndEscapesPlainTextAndAuthors() async throws {
        let client = JiraClient(transport: StubTransport([(200, issueJSON)]))
        let detail = try await client.issue(site: JiraSite("https://jira.example.com"), token: "token", id: "100")
        let html = IssueBodyHTML.document(detail: detail, baseURL: URL(string: "https://jira.example.com/jira")!, dark: false)
        XCTAssertFalse(html.contains("downloaded comments"))
        XCTAssertFalse(html.contains("Downloaded "), "The issue body must not show an unconditional download timestamp")
        XCTAssertTrue(html.contains("<strong>formatted</strong>"))
        XCTAssertTrue(html.contains("<p>Formatted comment</p>"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("https://jira.example.com/jira/"))
        XCTAssertEqual(IssueBodyHTML.escape(#"<script>alert("x")</script>&"#), "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;")
        let plainJSON = #"{"id":"100","key":"EX-1","fields":{"description":"<script>raw text</script>"},"renderedFields":{"comment":"unsupported format"}}"#
        let plain = try await JiraClient(transport: StubTransport([(200, plainJSON)])).issue(site: JiraSite("https://jira.example.com"), token: "token", id: "100")
        let plainHTML = IssueBodyHTML.document(detail: plain, baseURL: URL(string: "https://jira.example.com")!, dark: true)
        XCTAssertTrue(plainHTML.contains("&lt;script&gt;raw text&lt;/script&gt;"))
        XCTAssertFalse(plainHTML.contains("<script>raw text"))
    }
}

private actor DelayedIssueTransport: JiraTransport {
    private var pending: [String: (URL, CheckedContinuation<(Data, HTTPURLResponse), any Error>)] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.lastPathComponent == "remotelink" {
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = url.lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (url, continuation)
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    func waitForRequest(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func respond(_ id: String, body: String) {
        guard let (url, continuation) = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

private actor RecoveringIssueTransport: JiraTransport {
    private var failure: URLError.Code?

    init(failure: URLError.Code) { self.failure = failure }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.lastPathComponent == "remotelink" {
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if let failure {
            self.failure = nil
            throw URLError(failure)
        }
        return (Data(issueJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
