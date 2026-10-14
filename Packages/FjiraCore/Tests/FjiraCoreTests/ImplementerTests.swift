import Foundation
import GRDB
import XCTest
@testable import FjiraCore

private let implementerURL = URL(string: "https://jira.example.com/avatar/implementer.png")!
private let implementerPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGLsAAAAASUVORK5CYII=")!
private let implementerIssue = #"{"id":"100","key":"EX-1","fields":{"summary":"Fixture","priority":{"name":"High"},"assignee":{"name":"alice","displayName":"Alice Assignee"},"reporter":{"name":"carol","displayName":"Carol Reporter"},"customfield_77777":{"name":"bob","displayName":"Bob Implementer","avatarUrls":{"48x48":"https://jira.example.com/avatar/implementer.png"}}},"names":{"customfield_77777":"Implementer"}}"#

final class ImplementerTests: XCTestCase {
    func testCustomFieldDiscoveryAndPeopleOrdering() throws {
        let issue = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(implementerIssue.utf8))
        XCTAssertTrue(issue.hasImplementerField)
        XCTAssertEqual(issue.implementer?.displayName, "Bob Implementer")
        let snapshot = CachedIssueDetail(issue: issue, response: Data(implementerIssue.utf8), fetchedAt: Date(),
                                         generation: UUID(), commentPages: [], previousComments: [])
        XCTAssertTrue(snapshot.imageURLs.contains(implementerURL))
        let html = IssueBodyHTML.document(detail: snapshot, baseURL: URL(string: "https://jira.example.com")!, dark: false,
            avatars: [implementerURL.absoluteString: CachedAvatar(data: implementerPNG, mimeType: "image/png", fetchedAt: Date())])
        let expression = try NSRegularExpression(pattern: "<dt>([^<]+)</dt>")
        let labels = expression.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .map { String(html[Range($0.range(at: 1), in: html)!]) }
        XCTAssertEqual(Array(labels.prefix(6)), ["Status", "Type", "Priority", "Assignee", "Implementer", "Reporter"])
        XCTAssertTrue(html.contains("Bob Implementer"))
        XCTAssertTrue(html.contains("class=\"avatar metadata-avatar\" src=\"data:image/png;base64,"))
        let differentID = try JSONDecoder().decode(JiraIssueDetail.self,
            from: Data(implementerIssue.replacingOccurrences(of: "customfield_77777", with: "customfield_12345").utf8))
        XCTAssertEqual(differentID.implementer?.name, "bob")
        let restored = try JSONDecoder().decode(JiraIssueDetail.self, from: JSONEncoder().encode(issue))
        XCTAssertTrue(restored.hasImplementerField)
        XCTAssertEqual(restored.implementer?.avatarURL, implementerURL)
    }

    func testEmptyImplementerShowsUnassignedAndAbsentFieldIsOmitted() throws {
        let json = #"{"id":"100","key":"EX-1","fields":{"customfield_42":null},"names":{"customfield_42":"Implementer"}}"#
        let issue = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(json.utf8))
        XCTAssertTrue(issue.hasImplementerField)
        XCTAssertNil(issue.implementer)
        let snapshot = CachedIssueDetail(issue: issue, response: Data(json.utf8), fetchedAt: Date(),
                                         generation: UUID(), commentPages: [], previousComments: [])
        let html = IssueBodyHTML.document(detail: snapshot, baseURL: URL(string: "https://jira.example.com")!, dark: false)
        XCTAssertTrue(html.contains("<dt>Implementer</dt><dd><span class=\"metadata-value\"><span>Unassigned</span></span></dd>"))
        let placeholder = CachedAvatar(data: implementerPNG, mimeType: "image/png", fetchedAt: Date()).dataURL
        let withIcons = IssueBodyHTML.document(detail: snapshot, baseURL: URL(string: "https://jira.example.com")!,
                                               dark: false, personPlaceholderDataURL: placeholder)
        XCTAssertEqual(withIcons.components(separatedBy: "person-placeholder").count - 1, 2,
                       "Both unassigned Assignee and Implementer should show the local placeholder")
        XCTAssertTrue(withIcons.contains("src=\"\(placeholder)\""))
        let absent = try JSONDecoder().decode(JiraIssueDetail.self, from: Data(#"{"id":"100","key":"EX-1","fields":{}}"#.utf8))
        XCTAssertFalse(absent.hasImplementerField)
        XCTAssertNil(absent.implementer)
    }

    @MainActor
    func testOldCachedProjectionRecoversImplementerAndAvatarOffline() async throws {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let detail = try await JiraClient(transport: StubTransport([(200, implementerIssue)]))
            .issue(site: site, token: "fixture-token", id: "100")
        try await cache.saveIssue(detail, site: site.identifier, account: "alice")
        // Only the Implementer avatar is needed for this fixture's metadata.
        try await cache.saveAvatar(CachedAvatar(data: implementerPNG, mimeType: "image/png", fetchedAt: Date()),
                                   site: site.identifier, account: "alice", url: implementerURL)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        var projection = try XCTUnwrap(old["issue"] as? [String: Any])
        projection.removeValue(forKey: "implementer")
        projection.removeValue(forKey: "hasImplementerField")
        old["issue"] = projection
        let payload = try JSONSerialization.data(withJSONObject: old)
        let database = await cache.database
        try await database.write { db in
            try db.execute(sql: "UPDATE response_cache SET payload = ? WHERE site = ? AND account = ? AND resource = ?",
                           arguments: [payload, site.identifier, "alice", "issue-detail:100"])
        }
        let transport = OfflineImplementerTransport()
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: transport), token: { "fixture-token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        XCTAssertTrue(reader.isOffline)
        XCTAssertEqual(reader.detail?.issue.implementer?.name, "bob")
        XCTAssertEqual(reader.detail?.generation, detail.generation)
        XCTAssertEqual(reader.avatars[implementerURL.absoluteString]?.data, implementerPNG)
        let requests = await transport.count
        XCTAssertEqual(requests, 1, "Cached Implementer avatars must be published without another download")
        reader.close()
    }

    func testRefreshClearsAnUnassignedImplementer() async throws {
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let empty = #"{"id":"100","key":"EX-1","fields":{"customfield_77777":null},"names":{"customfield_77777":"Implementer"}}"#
        let client = JiraClient(transport: StubTransport([(200, implementerIssue), (200, empty)]))
        try await cache.saveIssue(client.issue(site: site, token: "fixture-token", id: "100"), site: site.identifier, account: "alice")
        try await cache.saveIssue(client.issue(site: site, token: "fixture-token", id: "100"), site: site.identifier, account: "alice")
        let saved = try await cache.loadIssue(site: site.identifier, account: "alice", id: "100")
        XCTAssertTrue(saved?.issue.hasImplementerField == true)
        XCTAssertNil(saved?.issue.implementer)
    }
}

private actor OfflineImplementerTransport: JiraTransport {
    private(set) var count = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        throw URLError(.notConnectedToInternet)
    }
}
