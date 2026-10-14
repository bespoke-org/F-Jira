import Foundation

/// A default reading order, independent of Jira's arbitrary status IDs and names.
/// Board-specific ordering can replace this policy once a board is selected.
public struct JiraStatusSortKey: Comparable, Sendable {
    private let rank: Int
    private let name: String

    public init(name: String?, category: JiraStatusCategory?) {
        let normalized = name?.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() ?? ""
        self.name = normalized
        if let index = Self.workflowNames.firstIndex(where: { $0.contains(normalized) }) {
            rank = index * 10
        } else if normalized.isEmpty {
            rank = 100
        } else if let category {
            // Keep unfamiliar statuses within their broad workflow phase.
            switch category.tone {
            case .neutral: rank = 15    // After Backlog, before Analysis.
            case .inProgress: rank = 75 // Before Done.
            case .done: rank = 85       // After Done.
            }
        } else {
            rank = 95
        }
    }

    private static let workflowNames = [
        ["new"], ["backlog"], ["analysis"], ["developing", "in progress"], ["reviewing", "review"],
        ["ready for testing"], ["testing"], ["ready to release", "ready for release"], ["done"]
    ]

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank == rhs.rank ? lhs.name < rhs.name : lhs.rank < rhs.rank
    }
}
