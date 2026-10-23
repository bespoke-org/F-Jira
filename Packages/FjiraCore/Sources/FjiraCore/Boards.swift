import Foundation

public struct JiraBoard: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let type: String

    public func webURL(site: JiraSite) -> URL {
        var components = URLComponents(url: site.url.appending(path: "secure/RapidBoard.jspa"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "rapidView", value: String(id))]
        return components.url!
    }
}

public struct BoardConfiguration: Codable, Sendable {
    public let id: Int
    public let name: String
    public let columnConfig: ColumnConfiguration
    public let subQuery: SubQuery?

    public struct ColumnConfiguration: Codable, Sendable {
        public let columns: [Column]
        public let constraintType: String?
    }
    public struct Column: Codable, Sendable {
        public let name: String
        public let statuses: [Status]
        public let min: Int?
        public let max: Int?
    }
    public struct Status: Codable, Sendable { public let id: String }
    public struct SubQuery: Codable, Sendable { public let query: String? }

    func excludingKanbanBacklog(_ enabled: Bool) -> BoardConfiguration {
        guard enabled else { return self }
        return BoardConfiguration(id: id, name: name,
            columnConfig: ColumnConfiguration(columns: Array(columnConfig.columns.dropFirst()), constraintType: columnConfig.constraintType),
            subQuery: subQuery)
    }

    /// Filtering by configured status IDs excludes unmapped/backlog statuses while preserving server rank.
    func issueFilter(board: JiraBoard, column: Int? = nil) throws -> String {
        if let column, !columnConfig.columns.indices.contains(column) { throw JiraError.invalidResponse }
        let ids = (column.map { columnConfig.columns[$0].statuses } ?? columnConfig.columns.flatMap(\.statuses)).map(\.id)
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            throw JiraError.invalidResponse
        }
        var clauses = ["status in (\(ids.joined(separator: ",")))"]
        if board.type == "scrum" { clauses.append("sprint in openSprints()") }
        if board.type == "kanban", let query = subQuery?.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            clauses.append("(\(query))")
        }
        return clauses.joined(separator: " AND ")
    }
}

public struct CachedBoards: Codable, Sendable {
    public let boards: [JiraBoard]
    public let fetchedAt: Date
    public let responses: [Data]
}

public struct CachedBoard: Codable, Sendable {
    public let board: JiraBoard
    public let configuration: BoardConfiguration
    public let configurationResponse: Data
    public var pages: [CachedIssuePage]
    public var isComplete: Bool
    public let fetchedAt: Date

    // Optional fields keep existing whole-board snapshots readable.
    public var columnPages: [Int: [CachedIssuePage]]? = nil
    public var retainedIssues: [JiraIssue]? = nil
    public var laneSnapshots: [CachedBoardLane]? = nil
    public var swimlanesResponse: Data? = nil
    public var completedIssuesCutoff: String? = nil
    var issueOverrides: [String: JiraIssue]? = nil

    public func requestScope(column: Int) -> (column: Int, filter: String?) {
        guard let laneSnapshots, !laneSnapshots.isEmpty else { return (column, nil) }
        let count = configuration.columnConfig.columns.count
        return (column % count, laneSnapshots[column / count].lane.filter)
    }

    public func lanes(matching text: String = "", assignee: String? = nil, limits: [Int: Int]? = nil) -> [BoardLane] {
        guard let laneSnapshots else { return [] }
        let count = configuration.columnConfig.columns.count
        return laneSnapshots.enumerated().map { index, saved in
            let localLimits = limits.map { limits in Dictionary(uniqueKeysWithValues:
                (0..<count).map { ($0, limits[index * count + $0] ?? 50) }) }
            let columns = saved.board.columns(matching: text, assignee: assignee, limits: localLimits).map { column in
                BoardColumn(id: index * count + column.id, configuration: column.configuration, issues: column.issues,
                            total: column.total, hasMore: column.hasMore, containsOlderIssues: column.containsOlderIssues)
            }
            return BoardLane(id: saved.lane.id, name: saved.lane.name, columns: columns)
        }
    }

    private var activePages: [CachedIssuePage] {
        if let laneSnapshots { return laneSnapshots.flatMap { $0.board.activePages } }
        return columnPages.map { pages in pages.keys.sorted().flatMap { pages[$0] ?? [] } } ?? pages
    }

    public var issues: [JiraIssue] {
        let loaded = laneSnapshots.map { $0.flatMap { $0.board.issues } }
            ?? (activePages.flatMap(\.page.issues) + (retainedIssues ?? []))
        return JiraIssue.newest(loaded).map { issue in
            issueOverrides?[issue.id].map { issue.accepting($0) } ?? issue
        }
    }

    public func reconciling(_ latest: [JiraIssue], preferOnEqual: Bool = true) -> CachedBoard {
        var result = self
        let known = Dictionary(uniqueKeysWithValues: JiraIssue.newest(latest).map { ($0.id, $0) })
        result.issueOverrides = issueOverrides ?? [:]
        for issue in issues {
            if let newer = known[issue.id] { result.issueOverrides?[issue.id] = issue.accepting(newer, onEqual: preferOnEqual) }
        }
        if let lanes = laneSnapshots {
            let shared = result.issues
            result.laneSnapshots = lanes.map { saved in
                var lane = saved
                lane.board = saved.board.reconciling(shared)
                return lane
            }
        }
        return result
    }

    private func isExpiredCompletedIssue(_ issue: JiraIssue) -> Bool {
        guard let cutoff = completedIssuesCutoff,
              cutoff.first == "-", let unit = cutoff.last, unit == "w" || unit == "d",
              let amount = Double(cutoff.dropFirst().dropLast()), amount > 0,
              let updated = issue.revision,
              let status = issue.fields.status?.id,
              configuration.columnConfig.columns.last(where: { !$0.statuses.isEmpty })?.statuses.contains(where: { $0.id == status }) == true
        else { return false }
        return updated < fetchedAt.addingTimeInterval(-amount * (unit == "w" ? 7 : 1) * 86_400)
    }

    public func hasNextPage(column: Int) -> Bool {
        if let laneSnapshots {
            let count = configuration.columnConfig.columns.count
            return laneSnapshots[column / count].board.hasNextPage(column: column % count)
        }
        guard let columnPages else { return !isComplete }
        guard let pages = columnPages[column], let last = pages.last else {
            return !configuration.columnConfig.columns[column].statuses.isEmpty
        }
        let next = last.page.startAt + last.page.issues.count
        return !last.page.issues.isEmpty && (last.page.total.map { next < $0 } ?? (last.page.issues.count >= last.page.maxResults))
    }

    public func nextStartAt(column: Int) -> Int {
        if let laneSnapshots {
            let count = configuration.columnConfig.columns.count
            return laneSnapshots[column / count].board.nextStartAt(column: column % count)
        }
        return columnPages?[column]?.last.map { $0.page.startAt + $0.page.issues.count } ?? 0
    }

    mutating func append(_ page: CachedIssuePage, column: Int) throws {
        if laneSnapshots != nil {
            let count = configuration.columnConfig.columns.count
            try laneSnapshots![column / count].board.append(page, column: column % count)
            isComplete = laneSnapshots!.allSatisfy { $0.board.isComplete }
            return
        }
        guard page.page.startAt == nextStartAt(column: column) else { throw SearchError.inconsistentPagination }
        let oldIDs = Set((columnPages?[column] ?? []).flatMap(\.page.issues).map(\.id))
        guard page.page.issues.isEmpty || page.page.issues.contains(where: { !oldIDs.contains($0.id) }) else {
            throw SearchError.inconsistentPagination
        }
        if columnPages == nil { columnPages = [:] }
        columnPages?[column, default: []].append(page)
        let currentIDs = Set(activePages.flatMap(\.page.issues).map(\.id))
        let completeStatuses = Set(configuration.columnConfig.columns.enumerated()
            .filter { !hasNextPage(column: $0.offset) }.flatMap { $0.element.statuses.map(\.id) })
        retainedIssues = retainedIssues?.filter {
            !currentIDs.contains($0.id) && !($0.fields.status?.id.map(completeStatuses.contains) ?? false)
        }
        isComplete = configuration.columnConfig.columns.indices.allSatisfy { !hasNextPage(column: $0) }
    }
    public var imageURLs: [URL] { imageURLs(limits: [:]) }

    public func imageURLs(limits: [Int: Int]) -> [URL] {
        var seen = Set<URL>()
        let issues = columns(limits: limits).flatMap(\.issues)
        return (issues.compactMap { $0.fields.issuetype?.iconUrl }
            + issues.compactMap { $0.fields.priority?.iconUrl }
            + issues.compactMap { $0.fields.assignee?.avatarURL }).filter { seen.insert($0).inserted }
    }
    public var warnings: [String] { Array(Set(activePages.flatMap { $0.page.warningMessages ?? [] })).sorted() }

    public func columns(matching text: String = "", assignee: String? = nil, limits: [Int: Int]? = nil) -> [BoardColumn] {
        if laneSnapshots != nil { return lanes(matching: text, assignee: assignee, limits: limits).flatMap(\.columns) }
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtering = !terms.isEmpty || assignee != nil
        let all = issues
        let originals = Dictionary((activePages.flatMap(\.page.issues) + (retainedIssues ?? [])).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let retainedIDs = Set(retainedIssues?.map(\.id) ?? [])
        return configuration.columnConfig.columns.enumerated().map { index, column in
            let ids = Set(column.statuses.map(\.id))
            let matching = all.filter { issue in
                (issue.fields.status?.id.map(ids.contains) ?? false)
                    && !isExpiredCompletedIssue(issue)
                    && (assignee == nil || issue.fields.assignee?.identifier == assignee)
                    && terms.allSatisfy { issue.key.localizedCaseInsensitiveContains($0) || issue.summary.localizedCaseInsensitiveContains($0) }
            }
            // A corrected card follows existing cards in its destination column.
            let movedIDs = Set(matching.filter {
                originals[$0.id]?.fields.status?.id.map(ids.contains) != true
            }.map(\.id))
            let ordered = matching.filter { !movedIDs.contains($0.id) } + matching.filter { movedIDs.contains($0.id) }
            let visible = Array(ordered.prefix(limits.map { $0[index] ?? 50 } ?? ordered.count))
            let more = hasNextPage(column: index)
            let changedMembership = activePages.flatMap(\.page.issues).contains { original in
                guard let latest = issueOverrides?[original.id] else { return false }
                let wasHere = original.fields.status?.id.map(ids.contains) ?? false
                let isHere = (latest.fields.status?.id.map(ids.contains) ?? false) && !isExpiredCompletedIssue(latest)
                return wasHere != isHere
            }
            let total = !more ? matching.count : (changedMembership ? nil : columnPages?[index]?.last?.page.total)
            return BoardColumn(id: index, configuration: column, issues: visible,
                               total: filtering ? nil : total, hasMore: matching.count > visible.count || more,
                               containsOlderIssues: visible.contains { retainedIDs.contains($0.id) })
        }
    }
}

public struct BoardColumn: Identifiable, Sendable {
    public let id: Int
    public let configuration: BoardConfiguration.Column
    public let issues: [JiraIssue]
    public var total: Int? = nil
    public var hasMore: Bool = false
    public var containsOlderIssues: Bool = false
}

extension JiraClient {
    public func boards(site: JiraSite, token: String, projectID: String) async throws -> CachedBoards {
        struct Page: Decodable {
            let startAt: Int
            let maxResults: Int
            let total: Int?
            let isLast: Bool?
            let values: [JiraBoard]
        }
        var boards: [JiraBoard] = []
        var responses: [Data] = []
        var seen = Set<Int>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let data = try await fetch("board", site: site, token: token, queryItems: [
                URLQueryItem(name: "projectKeyOrId", value: projectID),
                URLQueryItem(name: "startAt", value: String(offset)),
                URLQueryItem(name: "maxResults", value: "50")
            ], agile: true)
            let page: Page = try decode(data)
            guard page.startAt == offset, page.maxResults > 0,
                  page.total.map({ $0 >= 0 }) ?? true else { throw SearchError.inconsistentPagination }
            responses.append(data)
            let newBoards = page.values.filter { seen.insert($0.id).inserted }
            boards.append(contentsOf: newBoards)
            offset += page.values.count
            if page.isLast == true || page.total.map({ offset >= $0 }) == true { break }
            if page.values.isEmpty {
                guard page.isLast != false, page.total.map({ offset >= $0 }) ?? true else { throw SearchError.inconsistentPagination }
                break
            }
            guard !newBoards.isEmpty else { throw SearchError.inconsistentPagination }
            if page.isLast == nil && page.total == nil && page.values.count < page.maxResults { break }
        }
        return CachedBoards(boards: boards, fetchedAt: Date(), responses: responses)
    }

    public func boardConfiguration(site: JiraSite, token: String, boardID: Int) async throws -> (BoardConfiguration, Data) {
        let data = try await fetch("board/\(boardID)/configuration", site: site, token: token, agile: true)
        let configuration: BoardConfiguration = try decode(data)
        guard configuration.id == boardID else { throw JiraError.invalidResponse }
        return (configuration, data)
    }

    public func boardIssues(site: JiraSite, token: String, board: JiraBoard,
                            configuration: BoardConfiguration, startAt: Int, column: Int? = nil, swimlaneFilter: String? = nil, completedIssuesCutoff: String? = nil,
                            maxResults: Int = 50, membershipOnly: Bool = false) async throws -> CachedIssuePage {
        var filter = try configuration.issueFilter(board: board, column: column)
        if let swimlaneFilter, !swimlaneFilter.isEmpty { filter += " AND (\(swimlaneFilter))" }
        if let cutoff = completedIssuesCutoff {
            guard cutoff.range(of: #"^-[1-9][0-9]*[wd]$"#, options: .regularExpression) != nil else {
                throw BoardSwimlaneError.invalidConfiguration
            }
            if let done = configuration.columnConfig.columns.last(where: { !$0.statuses.isEmpty }) {
                let ids = done.statuses.map(\.id)
                guard ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
                    throw JiraError.invalidResponse
                }
                filter += " AND (status not in (\(ids.joined(separator: ","))) OR updated >= \(cutoff))"
            }
        }
        let data = try await fetch("board/\(board.id)/issue", site: site, token: token, queryItems: [
            URLQueryItem(name: "startAt", value: String(startAt)),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "jql", value: filter),
            URLQueryItem(name: "fields", value: membershipOnly ? "status" : "summary,status,assignee,priority,updated,issuetype,project,flagged,epic")
        ], agile: true)
        let page: IssuePage = try decode(data)
        guard page.startAt == startAt, page.maxResults > 0,
              page.total.map({ $0 >= 0 }) ?? true,
              !(page.issues.isEmpty && (page.total ?? 0) > startAt) else { throw SearchError.inconsistentPagination }
        return CachedIssuePage(page: page, response: data, fetchedAt: Date())
    }
}
