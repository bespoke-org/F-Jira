import XCTest
@testable import FjiraCore

final class NavigationHistoryTests: XCTestCase {
    func testBackAndForwardReachTheirBoundariesWithoutRecordingVisits() {
        var history = NavigationHistory(initial: "list")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        history.visit("first")
        history.visit("second")
        XCTAssertEqual(history.goBack(), "first")
        XCTAssertEqual(history.goBack(), "list")
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), "first")
        XCTAssertEqual(history.goForward(), "second")
        XCTAssertNil(history.goForward())
    }

    func testNewVisitClearsForwardBranchButRefreshAndDuplicateVisitsDoNot() {
        var history = NavigationHistory(initial: "list")
        history.visit("first")
        history.visit("second")
        _ = history.goBack()
        history.visit("first")
        history.replaceCurrent("first")
        XCTAssertTrue(history.canGoForward)
        history.visit("third")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), "first")
        XCTAssertEqual(history.goForward(), "third")
        history.reset(to: "list")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBoundedHistoryKeepsItsMostRecentDestinations() {
        var history = NavigationHistory(initial: "list", limit: 3)
        history.visit("first")
        history.visit("second")
        history.visit("third")
        XCTAssertEqual(history.goBack(), "second")
        XCTAssertEqual(history.goBack(), "first")
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), "second")
    }
}
