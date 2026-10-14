import FjiraUI
import SwiftUI
import XCTest

@MainActor
final class JiraCommandTests: XCTestCase {
    func testShortcutsAreUniqueAndAppearInHelp() {
        let bindings = JiraCommand.allCases.map { "\($0.modifiers.rawValue):\($0.key.character)" }
        XCTAssertEqual(Set(bindings).count, bindings.count)
        XCTAssertEqual(JiraCommand.openInJira.key, "o")
        XCTAssertEqual(JiraCommand.refresh.key, "r")
        XCTAssertEqual(JiraCommand.openInJira.help, "Open in Jira (⌘O)")
        XCTAssertEqual(JiraCommand.refresh.help, "Refresh (⌘R)")
        XCTAssertEqual(JiraCommand.goBack.key, .leftArrow)
        XCTAssertEqual(JiraCommand.goForward.key, .rightArrow)
        XCTAssertEqual(JiraCommand.goBack.help, "Back (⌘←)")
        XCTAssertEqual(JiraCommand.goForward.help, "Forward (⌘→)")
    }

    func testUnavailableAndDisabledCommandsDoNotExecute() {
        var calls = 0
        let context = JiraCommandContext([
            .openInJira: JiraCommandAction(isEnabled: false) { calls += 1 },
            .refresh: JiraCommandAction { calls += 1 }
        ])
        XCTAssertFalse(context.isEnabled(.openInJira))
        XCTAssertFalse(context.isEnabled(.search))
        context.perform(.openInJira)
        context.perform(.search)
        XCTAssertEqual(calls, 0)
        context.perform(.refresh)
        XCTAssertEqual(calls, 1)
    }

    func testWindowContextsKeepActionsSeparate() {
        var opened: [String] = []
        let first = JiraCommandContext([.openInJira: JiraCommandAction { opened.append("first") }])
        let second = JiraCommandContext([.openInJira: JiraCommandAction { opened.append("second") }])
        second.perform(.openInJira)
        first.perform(.openInJira)
        XCTAssertEqual(opened, ["second", "first"])
    }
}
