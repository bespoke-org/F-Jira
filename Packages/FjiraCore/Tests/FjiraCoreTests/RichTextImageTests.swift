import Foundation
import XCTest
@testable import FjiraCore

private let smileURL = URL(string: "https://jira.example.com/jira/images/icons/emoticons/smile.gif")!
private let smileGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
private let emojiIssue = #"{"id":"100","key":"EX-1","fields":{"summary":"Fixture","description":"Hello :)","comment":{"comments":[{"id":"c1","body":"Reply :)"}]}},"renderedFields":{"description":"<p>Hello <img class=\"emoticon\" src=\"https://jira.example.com/jira/images/icons/emoticons/smile.gif\" alt=\":)\" width=\"16\" height=\"16\"></p>","comment":{"comments":[{"id":"c1","body":"<p>Reply <img class='emoticon' src='/jira/images/icons/emoticons/smile.gif' alt=':)' width='16' height='16'></p>"}]}}}"#

final class RichTextImageTests: XCTestCase {
    func testImageSourcesResolveEntitiesAndProjectContextAndRejectOtherOrigins() throws {
        let site = try JiraSite("https://jira.example.com/jira")
        let html = #"<img SRC=images/smile.gif alt='smile > happy'><IMG src="/jira/images/smile.gif"><img src='https://jira.example.com/jira/images/smile.gif'><img src="/secure/avatar?x=1&amp;y=2"><img src='&#47;jira/images/thumb.gif'><img data-src='/jira/ignored.gif'><img src='https://other.example.com/tracker.gif'><img src='http://jira.example.com/insecure.gif'><img src='https://user:pass@jira.example.com/private.gif'><!-- <img src='/jira/commented.gif'> -->"#
        let urls = JiraRichTextImages.urls(in: html, baseURL: site.url)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://jira.example.com/jira/images/smile.gif",
            "https://jira.example.com/secure/avatar?x=1&y=2",
            "https://jira.example.com/jira/images/thumb.gif"
        ])
        let tag = #"<img alt='smile > happy' src=/jira/images/icons/emoticons/smile.gif srcset='/jira/other.gif 2x' class=emoticon>"#
        let rewritten = JiraRichTextImages.embedding(tag, baseURL: site.url,
            images: [smileURL.absoluteString: CachedAvatar(data: smileGIF, mimeType: "image/gif", fetchedAt: Date())])
        XCTAssertTrue(rewritten.contains("data:image/gif;base64,"))
        XCTAssertTrue(rewritten.contains("alt='smile > happy'"))
        XCTAssertFalse(rewritten.contains("srcset="))
        XCTAssertFalse(rewritten.contains("/jira/other.gif"))
    }

    @MainActor
    func testReaderDownloadsSharedEmoticonOnceAndEmbedsItInDescriptionAndComment() async throws {
        let transport = EmojiImageTransport()
        let client = JiraClient(transport: transport)
        let site = try JiraSite("https://jira.example.com/jira")
        let issue = try await client.issue(site: site, token: "fixture-token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        let reader = IssueReader(site: site, account: "fixture", cache: cache, client: client, token: { "fixture-token" })
        reader.open(issue.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        await reader.remoteLinksTask?.value
        XCTAssertEqual(reader.avatars[smileURL.absoluteString]?.data, smileGIF)
        let html = IssueBodyHTML.document(detail: try XCTUnwrap(reader.detail), baseURL: site.url, dark: false, avatars: reader.avatars)
        XCTAssertEqual(html.components(separatedBy: "data:image/gif;base64,").count - 1, 2,
                       "Both description and comment emoticons must use cached image bytes")
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url == smileURL }.count, 1, "The same emoticon must be downloaded once")
        XCTAssertEqual(requests.first { $0.url == smileURL }?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        reader.close()
    }

    @MainActor
    func testEmoticonBytesRestoreOfflineFromExistingIssueSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "cache.sqlite").path
        let site = try JiraSite("https://jira.example.com/jira")
        let issue = try await JiraClient(transport: EmojiImageTransport()).issue(site: site, token: "fixture-token", id: "100")
        let cache = try ConnectionCache(path: path)
        try await cache.saveIssue(issue, site: site.identifier, account: "fixture")
        try await cache.saveAvatar(CachedAvatar(data: smileGIF, mimeType: "image/gif", fetchedAt: Date()),
                                   site: site.identifier, account: "fixture", url: smileURL)
        let reopened = try ConnectionCache(path: path)
        let transport = EmojiImageTransport(offline: true)
        let reader = IssueReader(site: site, account: "fixture", cache: reopened,
                                 client: JiraClient(transport: transport), token: { "fixture-token" })
        reader.open(issue.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        XCTAssertTrue(reader.isOffline)
        XCTAssertEqual(reader.avatars[smileURL.absoluteString]?.data, smileGIF)
        let html = IssueBodyHTML.document(detail: try XCTUnwrap(reader.detail), baseURL: site.url, dark: true, avatars: reader.avatars)
        XCTAssertEqual(html.components(separatedBy: "data:image/gif;base64,").count - 1, 2)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1, "Restoring cached emoticons must not require image downloads")
        reader.close()
    }
}

private actor EmojiImageTransport: JiraTransport {
    let offline: Bool
    private var captured: [URLRequest] = []
    init(offline: Bool = false) { self.offline = offline }
    func requests() -> [URLRequest] { captured }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let data = request.url == smileURL ? smileGIF : Data((request.url?.lastPathComponent == "remotelink" ? "[]" : emojiIssue).utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
