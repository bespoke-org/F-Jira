import Foundation
import XCTest
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
