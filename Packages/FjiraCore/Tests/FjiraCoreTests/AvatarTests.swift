import Foundation
import XCTest
import Observation
@testable import FjiraCore

private let fixturePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGLsAAAAASUVORK5CYII=")!

final class AvatarTests: XCTestCase {
    func testRedirectDoesNotSendTokenToExternalAvatarHost() async throws {
        let transport = ImageTransport(responses: [
            (302, Data(), ["Location": "https://images.example.com/alice.png"]),
            (200, fixturePNG, ["Content-Type": "image/png"])
        ])
        let image = try await JiraClient(transport: transport).avatar(site: JiraSite("https://jira.example.com/jira"), token: "private-token", url: URL(string: "https://jira.example.com/avatar/1")!)
        XCTAssertEqual(image.mimeType, "image/png")
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(image.data, fixturePNG)
    }

    func testAvatarCacheSurvivesRestartAndIsAccountScoped() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "cache.sqlite").path
        let url = URL(string: "https://jira.example.com/avatar/1")!
        let image = CachedAvatar(data: fixturePNG, mimeType: "image/png", fetchedAt: Date())
        let cache = try ConnectionCache(path: path)
        try await cache.saveAvatar(image, site: "site", account: "alice", url: url)
        let reopened = try ConnectionCache(path: path)
        let loaded = try await reopened.loadAvatar(site: "site", account: "alice", url: url)
        let other = try await reopened.loadAvatar(site: "site", account: "bob", url: url)
        XCTAssertEqual(loaded?.data, fixturePNG)
        XCTAssertNil(other)
    }

    @MainActor
    func testReaderLoadsAndReusesAvatarsOfflineWithVisibleAuthorHeader() async throws {
        let url = URL(string: "https://jira.example.com/avatar/alice.png")!
        let object: [String: Any] = ["id": "100", "key": "EX-1", "fields": [
            "summary": "Fixture", "comment": ["comments": [[
                "id": "c1", "body": "Comment", "author": ["displayName": "Alice Example", "name": "alice", "avatarUrls": ["48x48": url.absoluteString]]
            ]]]
        ]]
        let json = try JSONSerialization.data(withJSONObject: object)
        let site = try JiraSite("https://jira.example.com")
        let cache = try ConnectionCache(path: ":memory:")
        let online = ImageTransport(responses: [(200, json, [:]), (200, json, [:]), (200, fixturePNG, [:])])
        let client = JiraClient(transport: online)
        let detail = try await client.issue(site: site, token: "token", id: "100")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        XCTAssertEqual(reader.avatars[url.absoluteString]?.data, fixturePNG)
        let html = IssueBodyHTML.document(detail: try XCTUnwrap(reader.detail), baseURL: site.url, dark: false, avatars: reader.avatars)
        XCTAssertTrue(html.contains("Alice Example"))
        XCTAssertTrue(html.contains("class=\"avatar\""))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("src=\"https://jira.example.com/avatar"))
        reader.close()
        reader.open(detail.issue.listIssue)
        XCTAssertEqual(reader.detail?.issue.id, detail.issue.id)
        XCTAssertEqual(reader.avatars[url.absoluteString]?.data, fixturePNG, "Reopening must retain the author's image immediately")
        await reader.currentTask?.value
        await reader.avatarTask?.value
        let offline = ImageTransport(responses: [(503, Data(), [:])])
        let offlineReader = IssueReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: offline), token: { "token" })
        offlineReader.open(detail.issue.listIssue)
        await offlineReader.currentTask?.value
        await offlineReader.avatarTask?.value
        XCTAssertEqual(offlineReader.avatars[url.absoluteString]?.data, fixturePNG)
        XCTAssertNotNil(offlineReader.detail)
        XCTAssertNotNil(offlineReader.errorMessage)
        let requests = await offline.requests()
        XCTAssertEqual(requests.count, 1, "Cached avatars must not require a network request")
    }

    func testOlderConnectionRecoversProfileAvatarFromCachedRawResponse() async throws {
        let user = #"{"name":"alice","displayName":"Alice","avatarUrls":{"48x48":"https://jira.example.com/avatar/alice.png"}}"#
        let connection = try await JiraClient(transport: StubTransport([(200, user), (200, #"{"version":"9.12"}"#)]))
            .verify(site: JiraSite("https://jira.example.com"), token: "token")
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any])
        var oldUser = try XCTUnwrap(encoded["user"] as? [String: Any])
        oldUser.removeValue(forKey: "avatarUrls")
        encoded["user"] = oldUser
        let restored = try JSONDecoder().decode(CachedConnection.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(restored.user.avatarURL)
        XCTAssertEqual(restored.profileUser.avatarURL?.absoluteString, "https://jira.example.com/avatar/alice.png")
        XCTAssertEqual(restored.profileUser.identifier, restored.user.identifier)
    }

    @MainActor
    func testCachedMetadataImagesAreIncludedInFirstPublishedIssueState() async throws {
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: MetadataImageTransport())
        let detail = try await client.issue(site: site, token: "token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(detail, site: site.identifier, account: "alice")
        let urls = [detail.issue.fields.issuetype?.iconUrl, detail.issue.fields.priority?.iconUrl,
                    detail.issue.fields.assignee?.avatarURL, detail.issue.fields.reporter?.avatarURL].compactMap { $0 }
        for url in urls {
            let image = try await client.avatar(site: site, token: "token", url: url)
            try await cache.saveAvatar(image, site: site.identifier, account: "alice", url: url)
        }
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: MetadataImageTransport(offline: true)), token: { "token" })
        reader.open(detail.issue.listIssue)
        let published = expectation(description: "First issue publication")
        withObservationTracking { _ = reader.detail } onChange: {
            MainActor.assumeIsolated {
                XCTAssertEqual(reader.avatars.count, 4, "Cached icons and avatars must be ready before the first issue render")
                published.fulfill()
            }
        }
        await reader.currentTask?.value
        await fulfillment(of: [published], timeout: 1)
        reader.close()
    }

    @MainActor
    func testOldIssueSnapshotsRecoverCachedTypeAndPriorityIconsFromRawResponse() async throws {
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: MetadataImageTransport())
        let original = try await client.issue(site: site, token: "token", id: "100")
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var issue = try XCTUnwrap(encoded["issue"] as? [String: Any])
        var fields = try XCTUnwrap(issue["fields"] as? [String: Any])
        for name in ["issuetype", "priority"] {
            var field = try XCTUnwrap(fields[name] as? [String: Any])
            field.removeValue(forKey: "iconUrl")
            fields[name] = field
        }
        issue["fields"] = fields
        encoded["issue"] = issue
        let legacy = try JSONDecoder().decode(CachedIssueDetail.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(legacy.issue.fields.issuetype?.iconUrl)
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(legacy, site: site.identifier, account: "alice")
        for url in original.imageURLs {
            let image = try await client.avatar(site: site, token: "token", url: url)
            try await cache.saveAvatar(image, site: site.identifier, account: "alice", url: url)
        }
        let reader = IssueReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: MetadataImageTransport(offline: true)), token: { "token" })
        reader.open(original.issue.listIssue)
        await reader.currentTask?.value
        XCTAssertEqual(reader.detail?.issue.fields.issuetype?.iconUrl, original.issue.fields.issuetype?.iconUrl,
                       "Old snapshots must recover the type icon URL without waiting for a Jira refresh")
        XCTAssertEqual(reader.detail?.issue.fields.priority?.iconUrl, original.issue.fields.priority?.iconUrl)
        XCTAssertEqual(reader.avatars.count, 4)
        XCTAssertEqual(reader.detail?.generation, original.generation)
        XCTAssertEqual(reader.detail?.fetchedAt, original.fetchedAt)
        let html = IssueBodyHTML.document(detail: try XCTUnwrap(reader.detail), baseURL: site.url, dark: false, avatars: reader.avatars)
        XCTAssertTrue(html.contains("class=\"metadata-icon\" src=\"data:image/svg+xml;base64,"))
        reader.close()
    }

    @MainActor
    func testSharedImagesAreImmediatelyReusedForADifferentIssue() async throws {
        let site = try JiraSite("https://jira.example.com")
        let transport = MetadataImageTransport()
        let client = JiraClient(transport: transport)
        let first = try await client.issue(site: site, token: "token", id: "100")
        let second = try await client.issue(site: site, token: "token", id: "200")
        let cache = try ConnectionCache(path: ":memory:")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "token" })
        reader.open(first.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        reader.open(second.issue.listIssue)
        for url in [second.issue.fields.issuetype?.iconUrl, second.issue.fields.priority?.iconUrl, second.issue.fields.assignee?.avatarURL].compactMap({ $0 }) {
            XCTAssertNotNil(reader.avatars[url.absoluteString], "Images already seen on another issue must be reused synchronously")
        }
        let published = expectation(description: "New issue with shared images")
        withObservationTracking { _ = reader.detail } onChange: {
            MainActor.assumeIsolated {
                XCTAssertEqual(reader.avatars.count, 4, "A new issue must not first render without its known images")
                published.fulfill()
            }
        }
        await reader.currentTask?.value
        await reader.avatarTask?.value
        await reader.remoteLinksTask?.value
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(reader.detail?.issue.id, "200")
        let requests = await transport.requests()
        for name in ["alice.png", "bob.png", "task.svg", "high.svg"] {
            XCTAssertEqual(requests.filter { $0.lastPathComponent == name }.count, 1, "Shared image bytes must not be fetched again")
        }
        reader.close()
    }

    func testAcceptsStaticSVGIconsAndRejectsActiveOrExternalContent() async throws {
        let valid = ##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><defs><linearGradient id="g"><stop offset="0" stop-color="#2684ff"/></linearGradient></defs><path fill="url(#g)" d="M2 2h12v12H2z"/></svg>"##
        let url = URL(string: "https://jira.example.com/images/icons/task.svg")!
        let accepted = try await JiraClient(transport: ImageTransport(responses: [(200, Data(valid.utf8), [:])]))
            .avatar(site: JiraSite("https://jira.example.com"), token: "token", url: url)
        XCTAssertEqual(accepted.mimeType, "image/svg+xml")
        XCTAssertEqual(accepted.data, Data(valid.utf8))
        for body in [
            ##"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://other.example.com/photo.png"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg"><style>path {fill: url(https://other.example.com/style)}</style></svg>"##,
            #"<!DOCTYPE svg [<!ENTITY external SYSTEM "https://other.example.com/data">]><svg xmlns="http://www.w3.org/2000/svg"><text>&external;</text></svg>"#,
            ##"<svg xmlns="http://www.w3.org/2000/svg"><path>"##
        ] {
            do {
                _ = try await JiraClient(transport: ImageTransport(responses: [(200, Data(body.utf8), [:])]))
                    .avatar(site: JiraSite("https://jira.example.com"), token: "token", url: url)
                XCTFail("Expected invalid SVG rejection")
            } catch { XCTAssertEqual(error as? JiraError, .invalidResponse) }
        }
    }

    @MainActor
    func testMetadataIconsAndPeopleAvatarsLoadOnceAndRemainAvailableOffline() async throws {
        let site = try JiraSite("https://jira.example.com")
        let online = MetadataImageTransport()
        let client = JiraClient(transport: online)
        let detail = try await client.issue(site: site, token: "token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        let reader = IssueReader(site: site, account: "alice", cache: cache, client: client, token: { "token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        await reader.remoteLinksTask?.value
        XCTAssertEqual(reader.avatars.count, 4)
        XCTAssertEqual(reader.detail?.issue.fields.issuetype?.iconUrl?.lastPathComponent, "task.svg")
        let html = IssueBodyHTML.document(detail: try XCTUnwrap(reader.detail), baseURL: site.url, dark: false, avatars: reader.avatars)
        XCTAssertTrue(html.contains("class=\"metadata-icon\" src=\"data:image/svg+xml;base64,"))
        XCTAssertTrue(html.contains("class=\"avatar metadata-avatar\" src=\"data:image/png;base64,"))
        XCTAssertTrue(html.contains("Alice &amp; Example"))
        XCTAssertTrue(html.contains("Bob Reporter"))
        let requests = await online.requests()
        XCTAssertEqual(requests.filter { $0.lastPathComponent == "alice.png" }.count, 1, "A shared assignee/comment avatar must download once")
        reader.close()
        let offline = MetadataImageTransport(offline: true)
        let restored = IssueReader(site: site, account: "alice", cache: cache,
                                   client: JiraClient(transport: offline), token: { "token" })
        restored.open(detail.issue.listIssue)
        await restored.currentTask?.value
        await restored.avatarTask?.value
        XCTAssertEqual(restored.avatars.count, 4)
        let offlineHTML = IssueBodyHTML.document(detail: try XCTUnwrap(restored.detail), baseURL: site.url, dark: false, avatars: restored.avatars)
        XCTAssertTrue(offlineHTML.contains("data:image/svg+xml;base64,"))
        XCTAssertTrue(offlineHTML.contains("Bob Reporter"))
        let offlineRequests = await offline.requests()
        XCTAssertEqual(offlineRequests.count, 1, "Cached metadata images must not require network requests")
        restored.close()
    }

    func testRejectsHTMLAvatarAndInsecureRedirect() async throws {
        for responses in [
            [(200, Data("<html>Login</html>".utf8), ["Content-Type": "text/html"])],
            [(302, Data(), ["Location": "http://images.example.com/avatar.png"])]
        ] {
            do {
                _ = try await JiraClient(transport: ImageTransport(responses: responses)).avatar(
                    site: JiraSite("https://jira.example.com"), token: "token", url: URL(string: "https://jira.example.com/avatar")!
                )
                XCTFail("Expected invalid avatar response")
            } catch { XCTAssertTrue(error is JiraError) }
        }
    }
}

private actor ImageTransport: JiraTransport {
    let responses: [(Int, Data, [String: String])]
    private var captured: [URLRequest] = []
    private var responseIndex = 0
    init(responses: [(Int, Data, [String: String])]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        if request.url?.lastPathComponent == "remotelink" {
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let index = responseIndex
        responseIndex += 1
        guard index < responses.count else { throw URLError(.notConnectedToInternet) }
        let (status, data, headers) = responses[index]
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func requests() -> [URLRequest] { captured }
}

private actor MetadataImageTransport: JiraTransport {
    let offline: Bool
    private var captured: [URL] = []
    init(offline: Bool = false) { self.offline = offline }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        captured.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        let data: Data
        if url.lastPathComponent == "remotelink" { data = Data("[]".utf8) }
        else if url.pathExtension == "png" { data = fixturePNG }
        else if url.pathExtension == "svg" {
            data = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="#2684ff" d="M2 2h12v12H2z"/></svg>"##.utf8)
        } else {
            let alice: [String: Any] = ["name": "alice", "displayName": "Alice & Example", "avatarUrls": ["48x48": "https://jira.example.com/avatar/alice.png"]]
            let bob: [String: Any] = ["name": "bob", "displayName": "Bob Reporter", "avatarUrls": ["48x48": "https://jira.example.com/avatar/bob.png"]]
            data = try JSONSerialization.data(withJSONObject: ["id": url.lastPathComponent, "key": url.lastPathComponent == "200" ? "EX-2" : "EX-1", "fields": [
                "summary": "Metadata fixture", "assignee": alice, "reporter": bob,
                "issuetype": ["name": "Task", "iconUrl": "https://jira.example.com/icons/task.svg"],
                "priority": ["name": "High", "iconUrl": "https://jira.example.com/icons/high.svg"],
                "comment": ["comments": [["id": "c1", "body": "Comment", "author": alice]]]
            ]])
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func requests() -> [URL] { captured }
}
