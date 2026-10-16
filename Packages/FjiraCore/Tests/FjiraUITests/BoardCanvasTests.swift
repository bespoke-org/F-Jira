import AppKit
@testable import FjiraCore
import FjiraUI
import SwiftUI
import XCTest

@MainActor
final class BoardCanvasTests: XCTestCase {
    func testBoardScrollsHorizontallyAndColumnsKeepLongListsInsideViewport() async throws {
        _ = NSApplication.shared
        let names = ["To do", "In progress", "Review", "Done"]
        let columns = try names.enumerated().map { index, name in
            let configuration = BoardConfiguration.Column(name: name, statuses: [.init(id: String(index))], min: nil, max: nil)
            let issues = try (0..<(index == 0 ? 24 : 3)).map { number in
                let summaries = ["Improve search results and keyboard navigation", "Cache project images for offline use", "Review the release checklist"]
                var fields: [String: Any] = [
                    "summary": summaries[number % summaries.count], "status": ["id": String(index), "name": name],
                    "issuetype": ["name": "Task"], "priority": ["name": "Medium"],
                    "assignee": ["name": "alex", "displayName": "Alex"]]
                if number % 3 != 0 {
                    fields["epic"] = ["id": 999, "key": "DEMO-999",
                        "name": number % 2 == 0 ? "Offline access" : "Platform improvements and much longer epic names",
                        "color": ["key": "color_\(index + 2)"]]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "id": "\(index)-\(number)", "key": "DEMO-\(index * 100 + number)", "fields": fields])
                return try JSONDecoder().decode(JiraIssue.self, from: data)
            }
            return BoardColumn(id: index, configuration: configuration, issues: issues)
        }
        let canvas = BoardCanvas(columns: columns, images: [:], selectedKey: "DEMO-100", openIssue: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: canvas.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["FJIRA_BOARD_PREVIEW_PATH"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let vertical = scrollViews(host).filter { $0.hasVerticalScroller }
        XCTAssertEqual(vertical.count, 4)
        let first = try XCTUnwrap(vertical.first)
        XCTAssertGreaterThan(first.documentView!.frame.height, first.contentView.bounds.height)
        XCTAssertLessThanOrEqual(first.frame.height, 650)
        first.contentView.scroll(to: NSPoint(x: 0, y: 200))
        first.reflectScrolledClipView(first.contentView)
        XCTAssertGreaterThan(first.contentView.bounds.origin.y, 0)
        window.setContentSize(NSSize(width: 550, height: 650))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let horizontal = try XCTUnwrap(scrollViews(host).first { $0.hasHorizontalScroller })
        XCTAssertGreaterThan(horizontal.documentView!.frame.width, horizontal.contentView.bounds.width)
        horizontal.contentView.scroll(to: NSPoint(x: 250, y: 0))
        horizontal.reflectScrolledClipView(horizontal.contentView)
        XCTAssertGreaterThan(horizontal.contentView.bounds.origin.x, 0)
    }

    func testHorizontalScrollingDoesNotPageDoneButReachingItsBottomDoes() async throws {
        _ = NSApplication.shared
        var requests: [Int] = []
        let columns = try (0..<4).map { index in
            let config = BoardConfiguration.Column(name: index == 3 ? "Done" : "Stage \(index)",
                                                   statuses: [.init(id: String(index))], min: nil, max: nil)
            let issues = try (0..<(index == 3 ? 50 : 1)).map { number in
                let data = Data("{\"id\":\"\(index)-\(number)\",\"key\":\"EX-\(number)\",\"fields\":{\"summary\":\"Issue \(number)\"}}".utf8)
                return try JSONDecoder().decode(JiraIssue.self, from: data)
            }
            return BoardColumn(id: index, configuration: config, issues: issues,
                               total: index == 3 ? 550 : 1, hasMore: index == 3)
        }
        let canvas = BoardCanvas(columns: columns, images: [:], selectedKey: nil,
                                 loadMore: { requests.append($0) }, openIssue: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: canvas.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(requests.isEmpty, "Opening the board must not trigger another page")
        let horizontal = try XCTUnwrap(scrollViews(host).first { $0.hasHorizontalScroller })
        for position in stride(from: 0, through: 500, by: 50) {
            horizontal.contentView.scroll(to: NSPoint(x: position, y: 0))
            horizontal.reflectScrolledClipView(horizontal.contentView)
            host.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(requests.isEmpty, "Horizontal scrolling must not drain Done's remaining pages")
        let done = try XCTUnwrap(scrollViews(host).filter { $0.hasVerticalScroller }.last)
        for _ in 0..<10 {
            let bottom = max(0, done.documentView!.frame.height - done.contentView.bounds.height)
            done.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            done.reflectScrolledClipView(done.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            if !requests.isEmpty { break }
        }
        XCTAssertEqual(requests, [3], "Reaching Done's bottom should request only Done's next page")
    }

    func testSwimlanesShareHorizontalScrollAndStackVertically() async throws {
        _ = NSApplication.shared
        let lanes = try ["Expedite", "Regular work", "Improvements"].enumerated().map { laneIndex, name in
            let columns = try ["To do", "In progress", "Review", "Done"].enumerated().map { columnIndex, title in
                let config = BoardConfiguration.Column(name: title, statuses: [.init(id: String(columnIndex))], min: nil, max: nil)
                let issues = try (0..<(laneIndex == 1 ? 4 : 1)).map { number in
                    let data = try JSONSerialization.data(withJSONObject: [
                        "id": "\(laneIndex)-\(columnIndex)-\(number)", "key": "DEMO-\(laneIndex * 100 + columnIndex * 10 + number)",
                        "fields": ["summary": laneIndex == 0 ? "Resolve the urgent delivery issue" : "Improve the project workflow"]])
                    return try JSONDecoder().decode(JiraIssue.self, from: data)
                }
                return BoardColumn(id: laneIndex * 4 + columnIndex, configuration: config, issues: issues, total: issues.count)
            }
            return BoardLane(id: laneIndex, name: name, columns: columns)
        }
        let canvas = BoardCanvas(columns: lanes.flatMap(\.columns), lanes: lanes, images: [:], selectedKey: nil, openIssue: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: canvas.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollViews(host).filter(\.hasHorizontalScroller).count, 1,
                       "All swimlanes must keep their columns aligned in one horizontal viewport")
        let outer = try XCTUnwrap(scrollViews(host).first { $0.hasVerticalScroller })
        XCTAssertGreaterThan(outer.documentView!.frame.height, outer.contentView.bounds.height)
        outer.contentView.scroll(to: NSPoint(x: 0, y: 400))
        outer.reflectScrolledClipView(outer.contentView)
        XCTAssertGreaterThan(outer.contentView.bounds.origin.y, 0)
        outer.contentView.scroll(to: .zero)
        outer.reflectScrolledClipView(outer.contentView)
        window.setContentSize(NSSize(width: 350, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let headerRect = NSRect(x: 16, y: host.isFlipped ? 12 : host.bounds.height - 42, width: 300, height: 30)
        let headerBefore = try capture(host, rect: headerRect)
        let horizontal = try XCTUnwrap(scrollViews(host).first { $0.hasHorizontalScroller })
        horizontal.contentView.scroll(to: NSPoint(x: 600, y: 0))
        horizontal.reflectScrolledClipView(horizontal.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(horizontal.contentView.bounds.origin.x, 500)
        XCTAssertEqual(try capture(host, rect: headerRect), headerBefore,
                       "The swimlane title, count, and disclosure arrow must stay in place during horizontal scrolling")
        let headerPoint = NSPoint(x: 32, y: host.isFlipped ? 26 : host.bounds.height - 26)
        click(host.convert(headerPoint, to: nil), in: window)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollViews(host).filter(\.hasVerticalScroller).count, 9,
                       "The pinned header must remain clickable after scrolling")
        if let path = ProcessInfo.processInfo.environment["FJIRA_SWIMLANE_PREVIEW_PATH"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testOnlyExpandedSwimlaneFillsRemainingViewportAndResizes() async throws {
        _ = NSApplication.shared
        let lanes = try ["Expedite", "Regular work", "Improvements"].enumerated().map { laneIndex, name in
            let columns = try (0..<4).map { columnIndex in
                let config = BoardConfiguration.Column(name: "Stage \(columnIndex)", statuses: [.init(id: String(columnIndex))], min: nil, max: nil)
                let issues = try (0..<(laneIndex == 1 ? 20 : 1)).map { number in
                    let data = try JSONSerialization.data(withJSONObject: [
                        "id": "\(laneIndex)-\(columnIndex)-\(number)", "key": "DEMO-\(laneIndex * 100 + columnIndex * 20 + number)",
                        "fields": ["summary": "A card in \(name)"]])
                    return try JSONDecoder().decode(JiraIssue.self, from: data)
                }
                return BoardColumn(id: laneIndex * 4 + columnIndex, configuration: config, issues: issues, total: issues.count)
            }
            return BoardLane(id: laneIndex, name: name, columns: columns)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BoardCanvas(columns: lanes.flatMap(\.columns), lanes: lanes,
                                                       images: [:], selectedKey: nil, openIssue: { _ in }))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        let initialColumns = scrollViews(host).filter(\.hasVerticalScroller).dropFirst()
        let firstColumn = try XCTUnwrap(initialColumns.first)
        let firstHeaderPoint = laneHeaderPoint(above: firstColumn)
        click(firstHeaderPoint, in: window)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollViews(host).filter(\.hasVerticalScroller).count, 9)
        let lastColumn = try XCTUnwrap(scrollViews(host).filter(\.hasVerticalScroller).suffix(4).first)
        click(laneHeaderPoint(above: lastColumn), in: window)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let vertical = scrollViews(host).filter(\.hasVerticalScroller)
        XCTAssertEqual(vertical.count, 5, "Only the four columns in the expanded swimlane should remain")
        let outer = try XCTUnwrap(vertical.first)
        let column = try XCTUnwrap(vertical.dropFirst().first)
        let initialHeight = column.frame.height
        XCTAssertGreaterThan(initialHeight, outer.contentSize.height - 220,
                             "The remaining swimlane should fill the viewport below its headers")
        XCTAssertLessThanOrEqual(outer.documentView!.frame.height, outer.contentSize.height + 2,
                                 "All three headers and the expanded columns should fit without outer scrolling")
        XCTAssertGreaterThan(column.documentView!.frame.height, column.contentSize.height,
                             "Long columns must still scroll independently")

        window.setContentSize(NSSize(width: 1100, height: 800))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(initialHeight - column.frame.height, 200, accuracy: 2,
                       "The sole expanded swimlane should resize with the window")
        XCTAssertLessThanOrEqual(outer.documentView!.frame.height, outer.contentSize.height + 2)

        // The first collapsed header remains at the top after resizing.
        let top = NSPoint(x: 32, y: host.isFlipped ? 26 : host.bounds.height - 26)
        click(host.convert(top, to: nil), in: window)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollViews(host).filter(\.hasVerticalScroller).count, 9)
        XCTAssertGreaterThan(outer.documentView!.frame.height, outer.contentSize.height,
                             "Multiple expanded swimlanes should remain vertically scrollable")
    }

    func testBoardScrollFrameBudget() async throws {
        guard ProcessInfo.processInfo.environment["FJIRA_SCROLL_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in scrolling benchmark; requires a visible desktop")
        }
        _ = NSApplication.shared
        let lanes = try (0..<3).map { laneIndex in
            let columns = try (0..<10).map { columnIndex in
                let config = BoardConfiguration.Column(name: "Stage \(columnIndex)", statuses: [.init(id: String(columnIndex))], min: nil, max: nil)
                let count = laneIndex == 0 ? (columnIndex == 0 ? 4 : 0) : (laneIndex == 1 ? 6 : 3)
                let issues = try (0..<count).map { number in
                    let data = try JSONSerialization.data(withJSONObject: [
                        "id": "\(laneIndex)-\(columnIndex)-\(number)", "key": "DEMO-\(laneIndex * 100 + columnIndex * 10 + number)",
                        "fields": ["summary": "Improve search results and keyboard navigation for the project", "issuetype": ["name": "Task"], "priority": ["name": "Medium"], "assignee": ["name": "alex", "displayName": "Alex"]]])
                    return try JSONDecoder().decode(JiraIssue.self, from: data)
                }
                return BoardColumn(id: laneIndex * 10 + columnIndex, configuration: config, issues: issues, total: issues.count)
            }
            return BoardLane(id: laneIndex, name: "Lane \(laneIndex)", columns: columns)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BoardCanvas(columns: lanes.flatMap(\.columns), lanes: lanes, images: [:], selectedKey: nil, openIssue: { _ in }))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let horizontal = try XCTUnwrap(scrollViews(host).first { $0.hasHorizontalScroller })
        let vertical = try XCTUnwrap(scrollViews(host).first { $0.hasVerticalScroller })
        XCTAssertGreaterThan(vertical.documentView!.frame.height, vertical.contentSize.height)
        for (name, scroll, axis) in [("horizontal", horizontal, true), ("vertical", vertical, false), ("diagonal", horizontal, true)] {
            horizontal.contentView.scroll(to: .zero)
            vertical.contentView.scroll(to: .zero)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            var timings: [Double] = []
            for frame in 0..<(Int(ProcessInfo.processInfo.environment["FJIRA_SCROLL_FRAMES"] ?? "180") ?? 180) {
                let start = CFAbsoluteTimeGetCurrent()
                let extent = axis ? scroll.documentView!.frame.width - scroll.contentSize.width : scroll.documentView!.frame.height - scroll.contentSize.height
                let offset = max(0, extent) * CGFloat(frame % 90) / 89
                scroll.contentView.scroll(to: axis ? NSPoint(x: offset, y: 0) : NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                if name == "diagonal" {
                    let verticalExtent = max(0, vertical.documentView!.frame.height - vertical.contentSize.height)
                    vertical.contentView.scroll(to: NSPoint(x: vertical === horizontal ? offset : 0, y: verticalExtent * CGFloat(frame % 90) / 89))
                    vertical.reflectScrolledClipView(vertical.contentView)
                }
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                try await Task.sleep(for: .milliseconds(2))
            }
            timings.sort()
            let p95 = timings[Int(Double(timings.count - 1) * 0.95)]
            print("SCROLL_BENCHMARK \(name) median=\(timings[timings.count / 2])ms p95=\(p95)ms max=\(timings.last!)ms")
            XCTAssertLessThan(p95, 1000 / 120, "\(name) scrolling exceeds the 120 Hz frame budget")
        }
    }

    private func capture(_ view: NSView, rect: NSRect) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func laneHeaderPoint(above column: NSScrollView) -> NSPoint {
        // The column's scroll view starts below its 40-point title and the swimlane header.
        let frame = column.convert(column.bounds, to: nil)
        return NSPoint(x: frame.minX + 20, y: frame.maxY + 64)
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }
}
