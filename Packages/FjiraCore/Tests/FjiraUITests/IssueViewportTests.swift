import AppKit
@testable import FjiraCore
import FjiraUI
import SwiftUI
import Observation
import WebKit
import XCTest

@MainActor
final class IssueViewportTests: XCTestCase {
    func testActivityTabsSwitchInPlaceAndSupportKeyboardNavigation() async throws {
        _ = NSApplication.shared
        let json = #"{"id":"100","key":"EX-1","fields":{"summary":"Improve activity view","description":"Issue description stays above activity.","comment":{"comments":[{"id":"c1","body":"Comment body","author":{"displayName":"Comment author"}}]}},"changelog":{"startAt":0,"maxResults":1,"total":1,"histories":[{"id":"h1","created":"2026-10-15T10:00:00.000+0000","author":{"displayName":"History author"},"items":[{"field":"status","fromString":"Developing","toString":"Reviewing"}]}]}}"#
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: FixtureTransport(data: Data(json.utf8)))
        let detail = try await client.issue(site: site, token: "token", id: "100")
        let reader = IssueReader(site: site, account: "fixture", cache: try ConnectionCache(path: ":memory:"), client: client, token: { "token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: IssueDetailView(reader: reader, site: site, close: {}))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close(); reader.close() }
        var web: WKWebView?
        for _ in 0..<150 {
            web = findWebView(host)
            if let web, (try? await evaluate(web, "document.querySelector('.activity')?.dataset.tab ?? ''")) == "comments" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try XCTUnwrap(web)
        _ = try await evaluate(content, "window.activityMarker = 'same viewport'; document.getElementById('activity-history-tab').focus(); document.getElementById('activity-history-tab').click(); 'clicked'")
        for _ in 0..<150 {
            if (try? await evaluate(content, "document.querySelector('.history-entry')?.textContent ?? ''"))?.contains("Reviewing") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reader.activityTab, .history)
        let selected = try await evaluate(content, "document.getElementById('activity-history-tab').getAttribute('aria-selected')")
        XCTAssertEqual(selected, "true")
        let author = try await evaluate(content, "document.querySelector('.history-entry .author-name')?.textContent ?? ''")
        XCTAssertEqual(author, "History author")
        let text = try await evaluate(content, "document.body.textContent")
        XCTAssertTrue(text.contains("Issue description stays above activity."))
        XCTAssertFalse(text.contains("Comment body"))
        XCTAssertFalse(text.contains("GRDB."))
        let values = try await evaluate(content, "[...document.querySelectorAll('.history-value')].map(node => node.textContent).join(' → ')")
        XCTAssertEqual(values, "Developing → Reviewing")
        let marker = try await evaluate(content, "window.activityMarker ?? ''")
        XCTAssertEqual(marker, "same viewport")
        let focus = try await evaluate(content, "document.activeElement.id")
        XCTAssertEqual(focus, "activity-history-tab", "Updating the activity panel must preserve tab keyboard focus")
        _ = try await evaluate(content, "document.getElementById('activity-history-tab').dispatchEvent(new KeyboardEvent('keydown', {key: 'Home', bubbles: true})); 'pressed'")
        for _ in 0..<150 {
            if (try? await evaluate(content, "document.querySelector('.comment')?.textContent ?? ''"))?.contains("Comment body") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reader.activityTab, .comments)
        let comment = try await evaluate(content, "document.querySelector('.comment')?.textContent ?? ''")
        XCTAssertTrue(comment.contains("Comment body"))
        XCTAssertTrue(findWebView(host) === content)
    }

    func testLongCommentsStayInScrollableViewport() async throws {
        _ = NSApplication.shared
        let lines = (0..<40).map { "<p>Comment line \($0)</p>" }.joined()
        let object: [String: Any] = ["id":"100", "key":"EX-1", "fields": [
            "status": ["name": "QA & Review", "statusCategory": ["key": "indeterminate", "colorName": "yellow"]],
            "epic": ["id": 999, "key": "EX-99", "name": "Platform & tools", "color": ["key": "color_2"]],
            "summary":"Fixture", "components": [["name":"Engine"], ["name":"API"]],
            "assignee": ["name": "alice", "displayName": "Alice Assignee", "avatarUrls": ["48x48": "https://jira.example.com/avatar/alice.png"]],
            "reporter": ["name": "bob", "displayName": "Bob Reporter", "avatarUrls": ["48x48": "https://jira.example.com/avatar/bob.png"]],
            "issuetype": ["name": "Task", "iconUrl": "https://jira.example.com/icons/task.svg"],
            "priority": ["name": "High", "iconUrl": "https://jira.example.com/icons/high.svg"],
            "comment": ["comments": [["id":"c1", "body":"Comment", "author":["displayName":"Tester", "name":"tester"]]]]
        ], "renderedFields": ["description":"<p>Description</p>", "comment": ["comments": [["id":"c1", "body":lines]]]]]
        let transport = FixtureTransport(data: try JSONSerialization.data(withJSONObject: object))
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: transport)
        let detail = try await client.issue(site: site, token: "fixture-token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(detail, site: site.identifier, account: "fixture")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGLsAAAAASUVORK5CYII=")!
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="#2684ff" d="M2 2h12v12H2z"/></svg>"##.utf8)
        for path in ["avatar/alice.png", "avatar/bob.png", "icons/task.svg", "icons/high.svg"] {
            let vector = path.hasSuffix("svg")
            try await cache.saveAvatar(CachedAvatar(data: vector ? svg : png, mimeType: vector ? "image/svg+xml" : "image/png", fetchedAt: Date()),
                                       site: site.identifier, account: "fixture", url: site.url.appending(path: path))
        }

        let reader = IssueReader(site: site, account: "fixture", cache: cache, client: client, token: { "fixture-token" })
        reader.open(detail.issue.listIssue)
        await reader.currentTask?.value
        await reader.avatarTask?.value
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: IssueDetailView(reader: reader, site: site, close: {}))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close(); reader.close() }
        var web: WKWebView?
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            web = findWebView(host)
            if let web, let text = try? await evaluate(web, "document.body.textContent"), text.contains("Tester") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try XCTUnwrap(web)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.frame.height, 300, "The web view must stay inside the issue viewport")
        let scrollable = try await evaluate(content, "String(document.documentElement.scrollHeight > window.innerHeight)")
        XCTAssertEqual(scrollable, "true", "Long comments must scroll inside the bounded viewport")
        _ = try await evaluate(content, "window.scrollTo(0, document.documentElement.scrollHeight); 'done'")
        let scrolled = try await evaluate(content, "String(window.scrollY > 0)")
        XCTAssertEqual(scrolled, "true", "Comments below the fold must be reachable")
        let author = try await evaluate(content, "document.querySelector('.author-name')?.textContent ?? ''")
        XCTAssertEqual(author, "Tester")
        let avatar = try await evaluate(content, "String(document.querySelector('.comment-header .avatar')?.getBoundingClientRect().width ?? 0)")
        XCTAssertEqual(avatar, "36")
        let components = try await evaluate(content, "String(document.querySelectorAll('.chip').length)")
        XCTAssertEqual(components, "2")
        let metadata = try await evaluate(content, "String(document.querySelectorAll('.metadata img').length)")
        XCTAssertEqual(metadata, "4")
        let avatarSize = try await evaluate(content, "String(document.querySelector('.metadata-avatar')?.getBoundingClientRect().width ?? 0)")
        XCTAssertEqual(avatarSize, "20")
        let iconSize = try await evaluate(content, "String(document.querySelector('.metadata-icon')?.getBoundingClientRect().width ?? 0)")
        XCTAssertEqual(iconSize, "16")
        let vectorLoaded = try await evaluate(content, "String(document.querySelector('.metadata-icon')?.naturalWidth ?? 0)")
        XCTAssertEqual(vectorLoaded, "16", "SVG Jira icons must actually render")
        let epicName = try await evaluate(content, "document.querySelector('.epic-pill')?.textContent ?? ''")
        XCTAssertEqual(epicName, "Platform & tools")
        let epicBackground = try await evaluate(content, "getComputedStyle(document.querySelector('.epic-pill')).backgroundColor")
        let dark = content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        XCTAssertEqual(epicBackground, dark ? "rgb(72, 52, 30)" : "rgb(255, 241, 224)")
        let statusName = try await evaluate(content, "document.querySelector('.status-pill')?.textContent ?? ''")
        XCTAssertEqual(statusName, "QA & Review")
        let statusBackground = try await evaluate(content, "getComputedStyle(document.querySelector('.status-pill')).backgroundColor")
        XCTAssertEqual(statusBackground, dark ? "rgb(28, 58, 94)" : "rgb(222, 235, 255)")


    }

    func testCachedIssueRendersWhileCredentialsAreSlow() async throws {
        _ = NSApplication.shared
        let object: [String: Any] = ["id": "100", "key": "EX-1", "fields": [
            "summary": "Cached issue", "description": "Cached description before refresh"
        ]]
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: FixtureTransport(data: try JSONSerialization.data(withJSONObject: object)))
        let detail = try await client.issue(site: site, token: "fixture-token", id: "100")
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(detail, site: site.identifier, account: "fixture")
        let reader = IssueReader(site: site, account: "fixture", cache: cache, client: client,
                                 token: { slowFixtureCredential() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: IssueDetailView(reader: reader, site: site, close: {}))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close(); reader.close() }
        reader.open(detail.issue.listIssue)
        let started = ContinuousClock.now
        var cachedTextVisible = false
        while started.duration(to: .now) < .seconds(1) {
            host.layoutSubtreeIfNeeded()
            if let web = findWebView(host),
               let text = try? await evaluate(web, "document.body.textContent"),
               text.contains("Cached description before refresh") {
                cachedTextVisible = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cachedTextVisible, "Cached details must render without waiting for credential lookup")
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertTrue(reader.isLoading, "Cached details must be visible while refresh is still pending")
        await reader.currentTask?.value
    }

    func testSwitchingIssuesKeepsViewportAndResetsScrollWithoutNavigation() async throws {
        _ = NSApplication.shared
        let lines = (0..<40).map { "Line \($0)" }.joined(separator: "\n\n")
        let firstJSON = try JSONSerialization.data(withJSONObject: [
            "id": "100", "key": "EX-1", "fields": ["summary": "First issue", "description": "First body\n\n" + lines]
        ])
        let secondJSON = try JSONSerialization.data(withJSONObject: [
            "id": "200", "key": "EX-2", "fields": ["summary": "Second issue", "description": "Second body\n\n" + lines]
        ])
        let site = try JiraSite("https://jira.example.com")
        let client = JiraClient(transport: SwitchingFixtureTransport(first: firstJSON, second: secondJSON))
        let cache = try ConnectionCache(path: ":memory:")
        let first = try await client.issue(site: site, token: "fixture-token", id: "100")
        let second = try await client.issue(site: site, token: "fixture-token", id: "200")
        try await cache.saveIssue(first, site: site.identifier, account: "fixture")
        try await cache.saveIssue(second, site: site.identifier, account: "fixture")
        let reader = IssueReader(site: site, account: "fixture", cache: cache, client: client, token: { "fixture-token" })
        reader.open(first.issue.listIssue)
        await reader.currentTask?.value
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: IssueDetailView(reader: reader, site: site, close: {}))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close(); reader.close() }
        var original: WKWebView?
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            original = findWebView(host)
            if let original, let text = try? await evaluate(original, "document.body.textContent"), text.contains("First body") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let originalWeb = try XCTUnwrap(original)
        _ = try await evaluate(originalWeb, "window.viewportMarker = 'same page'; window.scrollTo(0, 200); 'done'")
        reader.open(second.issue.listIssue)
        await reader.currentTask?.value
        var switched: WKWebView?
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            switched = findWebView(host)
            if let switched, let text = try? await evaluate(switched, "document.body.textContent"), text.contains("Second body") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let switchedWeb = try XCTUnwrap(switched)
        XCTAssertTrue(switchedWeb === originalWeb, "Switching issues must keep the existing viewport")
        let marker = try await evaluate(switchedWeb, "window.viewportMarker ?? ''")
        XCTAssertEqual(marker, "same page", "Replacing an issue must not navigate through an empty page")
        let position = try await evaluate(switchedWeb, "String(window.scrollY)")
        XCTAssertEqual(position, "0", "A different issue starts at the top")
        let text = try await evaluate(switchedWeb, "document.body.textContent")
        XCTAssertTrue(text.contains("Second body"))
        XCTAssertFalse(text.contains("First body"))
    }

    func testDocumentUpdatesPreserveScrollPosition() async throws {
        _ = NSApplication.shared
        let paragraphs = (0..<50).map { "<p>Line \($0)</p>" }.joined()
        let state = DocumentState(document: "<html><body><p>Initial</p>\(paragraphs)</body></html>")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DocumentHarness(state: state))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var web: WKWebView?
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            web = findWebView(host)
            if let web, let text = try? await evaluate(web, "document.body.textContent"), text.contains("Initial") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try XCTUnwrap(web)
        _ = try await evaluate(content, "window.scrollTo(0, 350); 'done'")
        state.document = state.document.replacingOccurrences(of: "Initial", with: "Updated")
        var position = "0"
        for _ in 0..<150 {
            if let text = try? await evaluate(content, "document.body.textContent"), text.contains("Updated") {
                position = try await evaluate(content, "String(window.scrollY)")
                if position == "350" { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(position, "350", "Avatar and comment updates must not jump to the top")
    }

    func testJiraEmoticonsRenderInlineFromCachedBytes() async throws {
        _ = NSApplication.shared
        let site = try JiraSite("https://jira.example.com/jira")
        let url = site.url.appending(path: "images/icons/emoticons/smile.gif")
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let object: [String: Any] = ["id": "100", "key": "EX-1", "fields": [
            "summary": "Fixture", "comment": ["comments": [["id": "c1", "body": "Reply :)"]]]
        ], "renderedFields": [
            "description": "<p id='emoji-description'>Hello <img class='emoticon' src='\(url.absoluteString)' alt=':)' width='16' height='16'> 🙂</p>",
            "comment": ["comments": [["id": "c1", "body": "<p id='emoji-comment'>Reply <img class='emoticon' src='/jira/images/icons/emoticons/smile.gif' alt=':)' width='16' height='16'></p>"]]]
        ]]
        let detail = try await JiraClient(transport: FixtureTransport(data: JSONSerialization.data(withJSONObject: object)))
            .issue(site: site, token: "fixture-token", id: "100")
        let image = CachedAvatar(data: gif, mimeType: "image/gif", fetchedAt: Date())
        let document = IssueBodyHTML.document(detail: detail, baseURL: site.url, dark: false,
                                              avatars: [url.absoluteString: image])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RenderedIssueBody(document: document))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var web: WKWebView?
        for _ in 0..<100 {
            web = findWebView(host)
            if let web, (try? await evaluate(web, "String(document.querySelectorAll('.emoticon').length)")) == "2" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try XCTUnwrap(web)
        for _ in 0..<100 {
            if (try? await evaluate(content, "String([...document.querySelectorAll('.emoticon')].every(img => img.complete && img.naturalWidth > 0))")) == "true" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let loaded = try await evaluate(content, "String([...document.querySelectorAll('.emoticon')].every(img => img.complete && img.naturalWidth > 0))")
        XCTAssertEqual(loaded, "true", "Jira emoticons must actually decode under the document CSP")
        for id in ["emoji-description", "emoji-comment"] {
            let size = try await evaluate(content, "String(document.querySelector('#\(id) img').getBoundingClientRect().width)")
            XCTAssertEqual(size, "16", "Jira emoticons must retain their inline icon size")
            let inline = try await evaluate(content, "String(getComputedStyle(document.querySelector('#\(id) img')).display)")
            XCTAssertEqual(inline, "inline")
        }
        let unicode = try await evaluate(content, "String(document.body.textContent.includes('🙂'))")
        XCTAssertEqual(unicode, "true")
    }

    func testUnassignedPlaceholderHasEnoughPixelsForRetinaDisplay() throws {
        for dark in [false, true] {
            let url = try XCTUnwrap(PersonAvatarPlaceholder.dataURL(dark: dark))
            let encoded = try XCTUnwrap(url.split(separator: ",").last)
            let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 40, "A 20-point avatar needs at least 40 pixels on Retina")
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 40)
        }
    }

    func testInlineMonospaceUsesMenloInDescriptionAndComments() async throws {
        _ = NSApplication.shared
        let markup = "<p>Inline <tt>legacy code</tt> and <code>code</code>.</p><pre>block code</pre>"
        let object: [String: Any] = ["id": "100", "key": "EX-1", "fields": [
            "summary": "Fixture", "comment": ["comments": [["id": "c1", "body": "Reply"]]]
        ], "renderedFields": [
            "description": markup,
            "comment": ["comments": [["id": "c1", "body": markup]]]
        ]]
        let site = try JiraSite("https://jira.example.com")
        let detail = try await JiraClient(transport: FixtureTransport(data: JSONSerialization.data(withJSONObject: object)))
            .issue(site: site, token: "fixture-token", id: "100")
        let document = IssueBodyHTML.document(detail: detail, baseURL: site.url, dark: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RenderedIssueBody(document: document))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var web: WKWebView?
        for _ in 0..<100 {
            web = findWebView(host)
            if let web, (try? await evaluate(web, "String(document.querySelectorAll('tt').length)")) == "2" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try XCTUnwrap(web)
        for tag in ["tt", "code", "pre"] {
            let usesMenlo = try await evaluate(content,
                "String([...document.querySelectorAll('\(tag)')].every(el => getComputedStyle(el).fontFamily.startsWith('Menlo')))")
            XCTAssertEqual(usesMenlo, "true", "\(tag) must use Menlo in both descriptions and comments")
        }
    }

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWebView($0) }.first
    }

    private func evaluate(_ web: WKWebView, _ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct FixtureTransport: JiraTransport {
    let data: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = request.url?.lastPathComponent == "remotelink" ? Data("[]".utf8) : data
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Observable
private final class DocumentState {
    var document: String
    init(document: String) { self.document = document }
}

private struct DocumentHarness: View {
    @Bindable var state: DocumentState
    var body: some View { RenderedIssueBody(document: state.document).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private func slowFixtureCredential() -> String {
    Thread.sleep(forTimeInterval: 2)
    return "fixture-token"
}

private struct SwitchingFixtureTransport: JiraTransport {
    let first: Data
    let second: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = request.url?.lastPathComponent == "remotelink" ? Data("[]".utf8)
            : request.url?.lastPathComponent == "200" ? second : first
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
