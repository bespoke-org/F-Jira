import AppKit
import FjiraUI
import SwiftUI
import XCTest
@testable import FjiraCore

@MainActor
final class DashboardViewTests: XCTestCase {
    func testDashboardFitsWideAndNarrowWindowsAndScrolls() async throws {
        _ = NSApplication.shared
        let reader = DashboardReader(site: try JiraSite("https://jira.example.com"), account: "fixture",
            cache: try ConnectionCache(path: ":memory:"), client: JiraClient(transport: DashboardPreviewTransport()), token: { "fixture" })
        reader.openProject("10000")
        await reader.currentTask?.value
        await reader.currentTask?.value
        await reader.commentTask?.value
        XCTAssertEqual(reader.sections.count, 3)
        XCTAssertEqual(reader.completion?.weeks.count, 10)
        XCTAssertFalse(reader.comments?.comments.isEmpty ?? true)
        for issue in reader.sections[.myIssues]?.issues.prefix(4) ?? [] { reader.recordViewed(issue, project: "10000") }
        let view = DashboardView(reader: reader, images: [:], selectedKey: nil,
                                 openIssue: { _ in }, openComment: { _ in }, browse: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        defer { reader.reset(); window.contentView = nil; window.close() }
        for width: CGFloat in [1400, 1100, 900, 520] {
            window.setContentSize(NSSize(width: width, height: 850))
            try await Task.sleep(for: .milliseconds(350))
            await reader.completionHistoryTask?.value
            host.layoutSubtreeIfNeeded()
            let columnWidth = width >= 900 ? width - 380 : width - 40
            let visibleWeeks = max(2, Int((columnWidth - 32 + 4) / 48))
            XCTAssertGreaterThanOrEqual(reader.completion?.weeks.count ?? 0, visibleWeeks)
            if width == 1400 { XCTAssertGreaterThan(visibleWeeks, 10) }
            let scroll = try XCTUnwrap(findScroll(host))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 1, "Cards should not cause horizontal overflow")
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            if ProcessInfo.processInfo.environment["FJIRA_DASHBOARD_PREVIEW"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fjira-dashboard-\(Int(width)).png"))
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100, "Dashboard content must be scrollable")
            scroll.contentView.scroll(to: .zero)
        }
    }

    private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
}

private struct DashboardPreviewTransport: JiraTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.url?.lastPathComponent == "myself" {
            data = Data(#"{"timeZone":"Europe/Saratov"}"#.utf8)
        } else if request.url?.lastPathComponent == "field" {
            data = Data(#"[{"id":"customfield_12345","name":"Implementer"}]"#.utf8)
        } else {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any]
            let jql = body?["jql"] as? String ?? ""
            if body?["maxResults"] as? Int == 0 {
                let count = jql.utf8.reduce(0) { $0 + Int($1) } % 9
                let response = try JSONSerialization.data(withJSONObject: ["total": count])
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let done = jql.contains("resolved >=")
            let next = jql.contains("statusCategory = \"To Do\"")
            let count = done ? 2 : next ? 4 : 12
            let names = ["Review the counter service rollout", "Поднятие сервиса RedxCounters", "Fix retry behavior after a network timeout", "Add configuration validation", "Prepare release notes"]
            let issues: [[String: Any]] = (1...count).map { number in
                let comment: [String: Any] = [
                    "id": String(number), "body": "I checked the latest build. The changes look good; we can move this to testing.",
                    "created": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-number * 3600))),
                    "author": ["displayName": number.isMultiple(of: 2) ? "Alice" : "Bob"]
                ]
                let status: [String: Any] = ["name": done ? "Done" : next ? "Backlog" : "Reviewing",
                                           "statusCategory": ["key": done ? "done" : next ? "new" : "indeterminate"]]
                let fields: [String: Any] = [
                    "summary": names[(number - 1) % names.count],
                    "updated": ISO8601DateFormatter().string(from: Date()), "status": status,
                    "priority": ["name": "High"], "issuetype": ["name": "Task"],
                    "assignee": ["name": "alice", "displayName": "Alice"],
                    "comment": ["startAt": 0, "maxResults": 50, "total": 1, "comments": [comment]]
                ]
                return ["id": String(number), "key": "EX-\(number)", "fields": fields]
            }
            data = try JSONSerialization.data(withJSONObject: ["startAt": 0, "maxResults": 50, "total": count, "issues": issues])
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
