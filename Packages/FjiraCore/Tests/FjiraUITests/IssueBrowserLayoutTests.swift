import AppKit
import FjiraUI
import Observation
import SwiftUI
import XCTest

@MainActor
final class IssueBrowserLayoutTests: XCTestCase {
    func testResizingWithinLayoutModeDoesNotRebuildIssueContent() async throws {
        _ = NSApplication.shared
        let counter = ContentBuildCounter()
        let content = IssueBrowserLayout(isIssuePresented: .constant(false)) {
            counter.buildIssues()
        } detail: {
            Text("Issue detail")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        counter.builds = 0

        // A sidebar animation changes the space offered to this layout on every frame.
        for width in stride(from: 1000, through: 1200, by: 10) {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertLessThanOrEqual(counter.builds, 2,
                                 "Resizing within the wide layout must not rebuild issue content each frame")

        window.setContentSize(NSSize(width: 900, height: 600))
        try await Task.sleep(for: .milliseconds(100))
        counter.builds = 0
        for width in stride(from: 900, through: 760, by: -10) {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertLessThanOrEqual(counter.builds, 2,
                                 "Resizing within the narrow layout must not rebuild issue content each frame")
    }

    func testSelectedIssueMovesBetweenSidePaneAndSheet() async throws {
        _ = NSApplication.shared
        let selection = LayoutSelection()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SelectionHarness(selection: selection))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        selection.presented = true
        try await waitFor { self.hasDetail(window.contentView) }
        XCTAssertTrue(window.sheets.isEmpty)

        window.setContentSize(NSSize(width: 850, height: 600))
        try await waitFor { window.sheets.first.map { self.hasDetail($0.contentView) } ?? false }
        XCTAssertTrue(selection.presented, "Changing layout must preserve the selected issue")

        window.setContentSize(NSSize(width: 1200, height: 600))
        try await waitFor { window.sheets.isEmpty && self.hasDetail(window.contentView) }
        XCTAssertTrue(selection.presented, "Closing the sheet to show the side pane must preserve selection")
        selection.presented = false
        try await waitFor { !self.hasDetail(window.contentView) && window.sheets.isEmpty }
    }

    private func hasDetail(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view.identifier?.rawValue == "fixture-issue-detail" || view.subviews.contains { hasDetail($0) }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The issue layout did not finish changing")
    }

}

@MainActor
private final class ContentBuildCounter {
    var builds = 0
    func buildIssues() -> some View {
        builds += 1
        return VStack {
            Text("Issues")
            Table((0..<100).map { FixtureIssue(id: $0) }) {
                TableColumn("Key") { Text("EX-\($0.id)") }
                TableColumn("Summary") { Text("Example issue \($0.id)") }
            }
        }
    }
}

private struct FixtureIssue: Identifiable { let id: Int }

@MainActor @Observable
private final class LayoutSelection { var presented = false }

private struct SelectionHarness: View {
    @Bindable var selection: LayoutSelection
    var body: some View {
        IssueBrowserLayout(isIssuePresented: $selection.presented) {
            Text("Issues").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            DetailMarker()
        }
    }
}

private struct DetailMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("fixture-issue-detail")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
