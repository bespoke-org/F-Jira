import Foundation
import XCTest
@testable import FjiraCore

private let linkedIssueJSON = #"{"id":"100","key":"EX-1","fields":{"summary":"Issue with MR","description":"Issue description","issuelinks":[{"id":"1","type":{"outward":"blocks"},"outwardIssue":{"id":"200","key":"EX-2","fields":{"summary":"Related issue"}}}]}}"#
private let remoteMRJSON = #"[{"id":42,"application":{"name":"GitLab","type":"gitlab"},"relationship":"relates to","object":{"url":"https://gitlab.example.com/team/repo/-/merge_requests/42","title":"MR !42 & fix","summary":"Fix <edge case>","status":{"resolved":true},"extra":"retained"}}]"#

final class RemoteIssueLinkTests: XCTestCase {
    func testRemoteLinkRelationshipDefaultsToLinksToWhenMissingOrBlank() async throws {
        let site = try JiraSite("https://jira.example.com")
        var detail = try await JiraClient(transport: RemoteLinkFixtureTransport())
            .issue(site: site, token: "token", id: "100")
        let cases: [(field: String, expected: String)] = [
            ("", "links to"),
            (#""relationship":null,"#, "links to"),
            (#""relationship":"","#, "links to"),
            (#""relationship":" \n\t ","#, "links to"),
            (#""relationship":"mentioned in","#, "mentioned in"),
            (#""relationship":"relates to <review>","#, "relates to &lt;review&gt;")
        ]
        for item in cases {
            let response = Data("""
                [{"id":42,\(item.field)"object":{"url":"https://example.com/review","title":"Review"}}]
                """.utf8)
            let links = try JSONDecoder().decode([RemoteIssueLink].self, from: response)
            detail.remoteLinks = CachedRemoteIssueLinks(links: links, response: response, fetchedAt: Date())
            // Reopen the cached payload as well: the fallback must not require a network refresh.
            let restored = try JSONDecoder().decode(CachedIssueDetail.self, from: JSONEncoder().encode(detail))
            for dark in [false, true] {
                let html = IssueBodyHTML.document(detail: restored, baseURL: site.url, dark: dark)
                XCTAssertTrue(html.contains("<span class=\"muted issue-link-label\">\(item.expected)</span> <a href=\"https://example.com/review\">Review</a>"), item.field)
            }
        }
    }

    func testLoadsRemoteLinksWithContextPathAndPreservesRawResponse() async throws {
        let transport = RemoteLinkFixtureTransport()
        let links = try await JiraClient(transport: transport).remoteIssueLinks(
            site: JiraSite("https://jira.example.com/jira"), token: "fixture-token", id: "100")
        XCTAssertEqual(links.links.first?.object.title, "MR !42 & fix")
        XCTAssertEqual(links.links.first?.object.status?.resolved, true)
        XCTAssertTrue(String(decoding: links.response, as: UTF8.self).contains("retained"))
        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/jira/rest/api/2/issue/100/remotelink")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testRemoteLinksSurviveRestartAndIssueRefreshButRejectOldGenerations() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: RemoteLinkFixtureTransport())
        let detail = try await client.issue(site: site, token: "token", id: "100")
        try await cache.saveIssue(detail, site: site.identifier, account: "alice")
        let links = try await client.remoteIssueLinks(site: site, token: "token", id: "100")
        try await cache.saveRemoteIssueLinks(links, site: site.identifier, account: "alice", id: "100", expectedGeneration: detail.generation)
        let reopened = try ConnectionCache(path: path)
        let saved = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(saved?.remoteLinks?.response, links.response)
        let otherAccount = try await reopened.loadIssue(site: site.identifier, account: "bob", id: "100")
        XCTAssertNil(otherAccount)
        let fresh = try await client.issue(site: site, token: "token", id: "100")
        try await reopened.saveIssue(fresh, site: site.identifier, account: "alice")
        let refreshed = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(refreshed?.remoteLinks?.links.first?.id, 42)
        do {
            try await reopened.saveRemoteIssueLinks(links, site: site.identifier, account: "alice", id: "100", expectedGeneration: detail.generation)
            XCTFail("A late remote-link response must not replace a new issue generation")
        } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
        let empty = CachedRemoteIssueLinks(links: [], response: Data("[]".utf8), fetchedAt: Date())
        try await reopened.saveRemoteIssueLinks(empty, site: site.identifier, account: "alice", id: "100", expectedGeneration: fresh.generation)
        let cleared = try await reopened.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertEqual(cleared?.remoteLinks?.links.count, 0, "A successful empty response removes deleted links")
    }

    @MainActor
    func testReaderShowsJiraAndMRLinksAndKeepsThemWhenLinkRefreshFails() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: RemoteLinkFixtureTransport())
        let issue = try await client.issue(site: site, token: "token", id: "100")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "token" })
        reader.open(issue.issue.listIssue)
        await reader.currentTask?.value
        await reader.remoteLinksTask?.value
        let loaded = try XCTUnwrap(reader.detail)
        let html = IssueBodyHTML.document(detail: loaded, baseURL: site.url, dark: false)
        XCTAssertTrue(html.contains("<h2>Issue Links</h2>"))
        XCTAssertTrue(html.contains("EX-2: Related issue"))
        XCTAssertTrue(html.contains("MR !42 &amp; fix"))
        XCTAssertTrue(html.contains("<span class=\"muted issue-link-label\">relates to · GitLab · Resolved</span>"))
        XCTAssertTrue(html.contains("href=\"https://gitlab.example.com/team/repo/-/merge_requests/42\""))
        XCTAssertTrue(html.contains("Fix &lt;edge case&gt;"))
        XCTAssertTrue(html.contains("<hr class=\"description-divider\">"))
        reader.close()
        let failed = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: RemoteLinkFixtureTransport(remoteStatus: 503)), token: { "token" })
        failed.open(issue.issue.listIssue)
        await failed.currentTask?.value
        await failed.remoteLinksTask?.value
        XCTAssertEqual(failed.detail?.remoteLinks?.links.first?.id, 42)
        XCTAssertNotNil(failed.remoteLinksError)
        XCTAssertNil(failed.errorMessage, "Failure to load optional links must not replace the main issue")
        failed.close()
        let offline = IssueReader(site: site, account: "alice", cache: cache,
                                  client: JiraClient(transport: RemoteLinkFixtureTransport(offline: true)), token: { "token" })
        offline.open(issue.issue.listIssue)
        await offline.currentTask?.value
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.detail?.remoteLinks?.links.first?.object.title, "MR !42 & fix")
        offline.close()
    }

    func testOlderIssueSnapshotsWithoutRemoteLinksStillDecode() async throws {
        let detail = try await JiraClient(transport: RemoteLinkFixtureTransport())
            .issue(site: JiraSite("https://jira.example.com"), token: "token", id: "100")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        object.removeValue(forKey: "remoteLinks")
        let restored = try JSONDecoder().decode(CachedIssueDetail.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.remoteLinks)
        XCTAssertEqual(restored.issue.id, "100")
    }
}

private actor RemoteLinkFixtureTransport: JiraTransport {
    let remoteStatus: Int
    let offline: Bool
    private var last: URLRequest?

    init(remoteStatus: Int = 200, offline: Bool = false) {
        self.remoteStatus = remoteStatus
        self.offline = offline
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        last = request
        if offline { throw URLError(.notConnectedToInternet) }
        let remote = request.url?.lastPathComponent == "remotelink"
        return (Data((remote ? remoteMRJSON : linkedIssueJSON).utf8),
                HTTPURLResponse(url: request.url!, statusCode: remote ? remoteStatus : 200, httpVersion: nil, headerFields: nil)!)
    }

    func lastRequest() -> URLRequest? { last }
}
