import AppKit
import FjiraUI
import SwiftUI
import XCTest

@MainActor
final class BoardFilterFocusTests: XCTestCase {
    func testClickingOutsideToolbarFilterEndsEditing() async throws {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var text = ""
        let filter = BoardFilterField(text: Binding(get: { text }, set: { text = $0 }))
        let contentView: AnyView
        if #available(macOS 26.0, *) {
            contentView = AnyView(filter.frame(height: 36).background(ToolbarGlassBackground()))
        } else {
            contentView = AnyView(filter)
        }
        let host = NSHostingView(rootView: contentView)
        host.frame = NSRect(x: 0, y: 0, width: 150, height: 36)
        let delegate = FilterToolbarDelegate(host: host)
        let toolbar = NSToolbar(identifier: "filter-focus-test")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        let content = NSView()
        let otherField = NSTextField(frame: NSRect(x: 250, y: 150, width: 200, height: 24))
        content.addSubview(otherField)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(findField(host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        editor.insertText("before")
        let inside = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        click(inside, window: window, app: app)
        XCTAssertNotNil(field.currentEditor(), "Clicking inside must preserve editing")
        click(NSPoint(x: 100, y: 100), window: window, app: app)
        XCTAssertNil(field.currentEditor(), "Clicking the board must stop typing into the filter")
        XCTAssertEqual(text, "before", "Ending editing must preserve the filter")

        XCTAssertTrue(window.makeFirstResponder(field))
        click(otherField.convert(NSPoint(x: 30, y: 12), to: nil), window: window, app: app)
        XCTAssertNil(field.currentEditor())
        XCTAssertNotNil(otherField.currentEditor(), "The same click must focus the other text field")
        otherField.currentEditor()?.insertText("elsewhere")
        XCTAssertEqual(text, "before", "Typing elsewhere must not change the board filter")
        click(NSPoint(x: 100, y: 100), window: window, app: app)
        XCTAssertNotNil(otherField.currentEditor(), "The filter must not dismiss other text editors")
    }

    private func findField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }

    private func click(_ point: NSPoint, window: NSWindow, app: NSApplication) {
        let release = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        // Native text fields run a tracking loop while handling mouse-down.
        app.postEvent(release, atStart: true)
        let press = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        app.sendEvent(press)
        if let pending = app.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            app.sendEvent(pending)
        }
    }
}

@MainActor
private final class FilterToolbarDelegate: NSObject, NSToolbarDelegate {
    let host: NSView
    init(host: NSView) { self.host = host }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("filter")] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("filter")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = host
        return item
    }
}
