import Foundation
import XCTest
@testable import FjiraCore

final class StatusOrderingTests: XCTestCase {
    func testTableComparatorUsesWorkflowOrderInBothDirections() throws {
        let names = ["New", "Backlog", "Analysis", "Developing", "Reviewing",
                     "Ready for testing", "Testing", "Ready to release", "Done"]
        let issues = try names.reversed().map { try issue($0) }
        let ascending = KeyPathComparator(\JiraIssue.statusSortKey)
        let descending = KeyPathComparator(\JiraIssue.statusSortKey, order: .reverse)
        XCTAssertEqual(issues.sorted(using: [ascending]).map(\.status), names)
        XCTAssertEqual(issues.sorted(using: [descending]).map(\.status), Array(names.reversed()))
    }

    func testActualReviewAndReleaseNamesFollowWorkflowRatherThanCategory() throws {
        let review = try issue("Review", category: "indeterminate")
        let release = try issue("Ready To Release", category: "new")
        let names = ["Developing", "Review", "Ready for Testing", "Testing", "Ready To Release", "Done"]
        let issues = try [release, issue("Done"), issue("Testing", category: "indeterminate"),
                          review, issue("Developing", category: "indeterminate"),
                          issue("Ready for Testing", category: "new")]
        XCTAssertLessThan(review.statusSortKey, release.statusSortKey)
        XCTAssertEqual(issues.sorted(using: [KeyPathComparator(\.statusSortKey)]).map(\.status), names)
        XCTAssertEqual(issues.sorted(using: [KeyPathComparator(\.statusSortKey, order: .reverse)]).map(\.status), Array(names.reversed()))
        let alternateRelease = try issue("Ready for release", category: "new")
        XCTAssertLessThan(try issue("Testing").statusSortKey, alternateRelease.statusSortKey)
        XCTAssertLessThan(alternateRelease.statusSortKey, try issue("Done").statusSortKey)
    }

    func testInProgressUsesDevelopmentStageBeforeReview() throws {
        let names = ["Analysis", "Developing", "In Progress", "Review", "Ready for Testing",
                     "Testing", "Ready To Release", "Done"]
        let issues = try names.reversed().map { try issue($0, category: "indeterminate") }
        XCTAssertEqual(issues.sorted(using: [KeyPathComparator(\.statusSortKey)]).map(\.status), names)
        XCTAssertEqual(issues.sorted(using: [KeyPathComparator(\.statusSortKey, order: .reverse)]).map(\.status), Array(names.reversed()))
    }

    func testUnfamiliarStatusesStayInTheirCategoryWithStableNameOrder() throws {
        let issues = try [
            issue("Done"), issue("Waiting", category: "indeterminate"),
            issue("New"), issue("Cancelled", category: "done"),
            issue("Backlog"), issue("To Do", category: "new"),
            issue("Ready to release"), issue("Blocked", category: "indeterminate"),
            issue("Analysis"), issue("Custom without category")
        ]
        let expected = ["New", "Backlog", "To Do", "Analysis", "Ready to release",
                        "Blocked", "Waiting", "Done", "Cancelled", "Custom without category"]
        XCTAssertEqual(issues.sorted(using: [KeyPathComparator(\.statusSortKey)]).map(\.status), expected)
    }

    func testNameNormalizationDoesNotChangeDisplayedStatus() throws {
        let normalized = try issue("  READY  For   Testing ", category: "new")
        XCTAssertEqual(normalized.statusSortKey, try issue("Ready for testing").statusSortKey)
        XCTAssertEqual(normalized.status, "  READY  For   Testing ")
        XCTAssertLessThan(try issue("Reviewing").statusSortKey, normalized.statusSortKey)
        XCTAssertLessThan(normalized.statusSortKey, try issue("Testing").statusSortKey)
    }

    func testMissingStatusAndLegacyCachedIssuesSortWithoutNetwork() throws {
        let legacy = try issue("Developing")
        let restored = try JSONDecoder().decode(JiraIssue.self, from: JSONEncoder().encode(legacy))
        let missing = try JSONDecoder().decode(JiraIssue.self, from: Data(#"{"id":"0","key":"EX-0","fields":{}}"#.utf8))
        XCTAssertEqual(restored.statusSortKey, legacy.statusSortKey)
        XCTAssertLessThan(restored.statusSortKey, try issue("Reviewing").statusSortKey)
        XCTAssertLessThan(try issue("Custom without category").statusSortKey, missing.statusSortKey)
    }

    private func issue(_ name: String, category: String? = nil) throws -> JiraIssue {
        var status: [String: Any] = ["name": name]
        if let category { status["statusCategory"] = ["key": category] }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": name, "key": "EX-1", "fields": ["status": status]
        ])
        return try JSONDecoder().decode(JiraIssue.self, from: data)
    }
}
