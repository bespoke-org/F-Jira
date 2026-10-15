import AppKit
@testable import FjiraCore
import FjiraUI
import SwiftUI
import XCTest

@MainActor
final class BoardOverscrollTests: XCTestCase {
    func testTrackpadGesturesStayWithinBoardEdges() async throws {
        _ = NSApplication.shared
        let columns = try (0..<4).map { index in
            let configuration = BoardConfiguration.Column(name: "Stage \(index)", statuses: [.init(id: String(index))], min: nil, max: nil)
            let issues = try (0..<(index == 0 ? 30 : 2)).map { number in
                try JSONDecoder().decode(JiraIssue.self, from: Data("{\"id\":\"\(index)-\(number)\",\"key\":\"EX-\(number)\",\"fields\":{\"summary\":\"Example card\"}}".utf8))
            }
            return BoardColumn(id: index, configuration: configuration, issues: issues)
        }
        let lanes = (0..<3).map { BoardLane(id: $0, name: "Lane \($0)", columns: columns) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BoardCanvas(columns: columns, lanes: lanes, images: [:], selectedKey: nil, openIssue: { _ in }))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let views = scrollViews(host)
        let horizontal = try XCTUnwrap(views.first { $0.hasHorizontalScroller })
        let vertical = views.filter { $0.hasVerticalScroller }
        for (scroll, horizontalAxis) in [(horizontal, true)] + vertical.prefix(2).map({ ($0, false) }) {
            horizontal.contentView.scroll(to: .zero)
            vertical.first?.contentView.scroll(to: .zero)
            for direction: Int32 in [1, -1, 1] {
                host.rootView = BoardCanvas(columns: columns, lanes: lanes, images: [:], selectedKey: direction > 0 ? "EX-1" : "EX-2", openIssue: { _ in })
                window.setContentSize(NSSize(width: direction > 0 ? 600 : 650, height: direction > 0 ? 500 : 550))
                try await Task.sleep(for: .milliseconds(60))
                // Exercise the boundary guard even if framework momentum enables elasticity.
                scroll.horizontalScrollElasticity = .allowed
                scroll.verticalScrollElasticity = .allowed
                let maximum = max(0, horizontalAxis ? scroll.documentView!.frame.width - scroll.contentSize.width
                                  : scroll.documentView!.frame.height - scroll.contentSize.height)
                scroll.contentView.scroll(to: horizontalAxis ? NSPoint(x: direction > 0 ? 0 : maximum, y: 0)
                                          : NSPoint(x: 0, y: direction > 0 ? 0 : maximum))
                scroll.reflectScrolledClipView(scroll.contentView)
                for frame in 0..<24 {
                    scroll.horizontalScrollElasticity = .allowed
                    scroll.verticalScrollElasticity = .allowed
                    let phase: Int64 = frame == 0 ? 1 : frame == 1 ? 2 : frame == 2 ? 4 : 0
                    let momentum: Int64 = frame < 3 ? 0 : frame == 3 ? 1 : frame == 23 ? 3 : 2
                    let delta: Int32 = frame == 2 || frame == 23 ? 0 : 40 * direction
                    let event = try trackpad(dx: horizontalAxis ? delta : 0,
                                             dy: horizontalAxis ? 0 : delta, phase: phase, momentum: momentum)
                    XCTAssertTrue(event.hasPreciseScrollingDeltas)
                    if frame == 3 { XCTAssertEqual(event.momentumPhase, .began) }
                    if frame > 3 && frame < 23 { XCTAssertEqual(event.momentumPhase, .changed) }
                    if horizontalAxis {
                        let bounds = scroll.contentView.bounds
                        let point = scroll.contentView.convert(NSPoint(x: bounds.minX + 40, y: bounds.minY + 40), to: host)
                        let target = try XCTUnwrap(host.hitTest(point))
                        target.scrollWheel(with: event)
                    } else {
                        scroll.scrollWheel(with: event)
                    }
                    try await Task.sleep(for: .milliseconds(8))
                    let origin = horizontalAxis ? scroll.contentView.bounds.minX : scroll.contentView.bounds.minY
                    let extent = max(0, horizontalAxis ? scroll.documentView!.frame.width - scroll.contentSize.width
                                     : scroll.documentView!.frame.height - scroll.contentSize.height)
                    XCTAssertGreaterThanOrEqual(origin, -0.5, "\(horizontalAxis ? "horizontal" : "vertical") moved past start")
                    XCTAssertLessThanOrEqual(origin, extent + 0.5, "\(horizontalAxis ? "horizontal" : "vertical") moved past end")
                }
                scroll.scrollWheel(with: try trackpad(dx: 0, dy: 0, phase: 4))
                try await Task.sleep(for: .milliseconds(60))

            }
        }
    }

    private func trackpad(dx: Int32, dy: Int32, phase: Int64, momentum: Int64 = 0) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: dy, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
