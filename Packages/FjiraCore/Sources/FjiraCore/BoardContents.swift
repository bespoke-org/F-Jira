import Foundation

extension CachedBoard {
    /// Ignore fetch times and response formatting when deciding whether a poll changed the board.
    func contentsSignature() throws -> Data {
        struct Lane: Encodable {
            let lane: BoardSwimlane
            let issues: [JiraIssue]
        }
        struct Contents: Encodable {
            let configuration: BoardConfiguration
            let cutoff: String?
            let issues: [JiraIssue]
            let lanes: [Lane]?
            let warnings: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Contents(configuration: configuration, cutoff: completedIssuesCutoff,
            issues: laneSnapshots == nil ? issues : [],
            lanes: laneSnapshots?.map { Lane(lane: $0.lane, issues: $0.board.issues) }, warnings: warnings))
    }
}

extension JiraClient {
    /// Fetch the board once for card fields and each positive lane query for membership.
    /// Every collection must be complete before set subtraction can assign the default lane.
    func boardContents(site: JiraSite, token: String, board: JiraBoard, configuration: BoardConfiguration,
                       configurationResponse: Data, settings: BoardSwimlaneSettings) async throws -> CachedBoard {
        let queries: [String?] = [nil] + settings.lanes.filter { !$0.isDefault }.map(\.query)
        let collections = try await withThrowingTaskGroup(of: (Int, [CachedIssuePage]).self) { group in
            func enqueue(_ index: Int) {
                group.addTask {
                    var pages: [CachedIssuePage] = []
                    var seen = Set<String>()
                    var offset = 0
                    if configuration.columnConfig.columns.allSatisfy({ $0.statuses.isEmpty }) { return (index, []) }
                    while true {
                        try Task.checkCancellation()
                        let page = try await boardIssues(site: site, token: token, board: board,
                            configuration: configuration, startAt: offset, swimlaneFilter: queries[index],
                            completedIssuesCutoff: settings.completedIssuesCutoff, maxResults: 100, membershipOnly: index != 0)
                        // Reject changing/overlapping pagination instead of silently dropping membership.
                        for issue in page.page.issues {
                            guard seen.insert(issue.id).inserted else { throw SearchError.inconsistentPagination }
                        }
                        pages.append(page)
                        offset += page.page.issues.count
                        if let total = page.page.total {
                            if offset >= total { break }
                        } else if page.page.issues.count < page.page.maxResults { break }
                        guard !page.page.issues.isEmpty else { throw SearchError.inconsistentPagination }
                    }
                    return (index, pages)
                }
            }
            var next = min(queries.count, Self.boardRequestLimit)
            for index in 0..<next { enqueue(index) }
            var result: [Int: [CachedIssuePage]] = [:]
            // A rolling pool lets another lane start as soon as one finishes.
            while let (index, pages) = try await group.next() {
                result[index] = pages
                if next < queries.count { enqueue(next); next += 1 }
            }
            return result
        }
        let universe = collections[0, default: []].flatMap(\.page.issues)
        let fetchedAt = Date()
        let warnings = Array(Set(collections.values.flatMap { $0.flatMap { $0.page.warningMessages ?? [] } })).sorted()
        func snapshot(_ issues: [JiraIssue]) throws -> CachedBoard {
            var result = CachedBoard(board: board, configuration: configuration, configurationResponse: configurationResponse,
                                     pages: [], isComplete: true, fetchedAt: fetchedAt)
            result.completedIssuesCutoff = settings.completedIssuesCutoff
            result.columnPages = [:]
            for (index, column) in configuration.columnConfig.columns.enumerated() {
                let statuses = Set(column.statuses.map(\.id))
                let cards = issues.filter { $0.fields.status?.id.map(statuses.contains) ?? false }
                let page = IssuePage(startAt: 0, maxResults: max(1, cards.count), total: cards.count,
                                     issues: cards, warningMessages: warnings)
                result.columnPages?[index] = [CachedIssuePage(page: page, response: try JSONEncoder().encode(page), fetchedAt: fetchedAt)]
            }
            return result
        }
        var result = try snapshot(settings.lanes.isEmpty ? universe : [])
        result.swimlanesResponse = settings.response
        if !settings.lanes.isEmpty {
            var assigned = Set<String>()
            var queryIndex = 1
            result.laneSnapshots = try settings.lanes.map { lane in
                let matches: Set<String>?
                if lane.isDefault { matches = nil }
                else {
                    matches = Set(collections[queryIndex, default: []].flatMap(\.page.issues).map(\.id))
                    queryIndex += 1
                }
                // Universe order is Jira rank. Positive queries cannot introduce cards outside the board.
                let cards = universe.filter { !assigned.contains($0.id) && (matches?.contains($0.id) ?? true) }
                assigned.formUnion(cards.map(\.id))
                return CachedBoardLane(lane: lane, board: try snapshot(cards))
            }
        }
        return result
    }
}
