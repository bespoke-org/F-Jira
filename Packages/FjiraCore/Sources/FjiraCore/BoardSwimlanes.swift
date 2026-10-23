import Foundation

public struct BoardSwimlane: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let query: String
    public let isDefault: Bool
    public let filter: String
}

public struct CachedBoardLane: Codable, Sendable {
    public let lane: BoardSwimlane
    public var board: CachedBoard
}

public struct BoardLane: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let columns: [BoardColumn]
    public var total: Int? {
        guard columns.allSatisfy({ $0.total != nil }) else { return nil }
        return columns.reduce(0) { $0 + ($1.total ?? 0) }
    }
    public var isEmpty: Bool { columns.allSatisfy { $0.issues.isEmpty && !$0.hasMore } }
}

public enum BoardSwimlaneError: LocalizedError {
    case unsupportedStrategy(String), invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .unsupportedStrategy(let strategy): "This board groups issues by \(strategy). Only query-based swimlanes are supported yet."
        case .invalidConfiguration: "Jira returned an unsupported swimlane configuration. Open the board in Jira to view its groups."
        }
    }
}

struct SwimlaneConfiguration: Decodable {
    let rapidViewId: Int
    let swimlaneStrategy: String
    let swimlanes: [Lane]
    struct Lane: Decodable {
        let id: Int
        let name: String
        let query: String?
        let isDefault: Bool
    }

    func lanes() throws -> [BoardSwimlane] {
        if swimlaneStrategy == "none" { return [] }
        guard swimlaneStrategy == "custom" else { throw BoardSwimlaneError.unsupportedStrategy(swimlaneStrategy) }
        guard !swimlanes.isEmpty, Set(swimlanes.map(\.id)).count == swimlanes.count,
              swimlanes.filter(\.isDefault).count == 1 else { throw BoardSwimlaneError.invalidConfiguration }
        return try (swimlanes.filter { !$0.isDefault } + swimlanes.filter(\.isDefault)).map { lane in
            let query = Self.withoutOrdering(lane.query ?? "")
            guard lane.isDefault || !query.isEmpty else { throw BoardSwimlaneError.invalidConfiguration }
            // First-match assignment happens by issue ID after fetching positive queries.
            // NOT(query) is not a set complement in JQL: it can discard empty fields.
            return BoardSwimlane(id: lane.id, name: lane.name, query: query,
                                 isDefault: lane.isDefault, filter: lane.isDefault ? "" : "(\(query))")
        }
    }

    static func withoutOrdering(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var depth = 0
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if let activeQuote = quote {
                if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0, text[index...].range(of: #"(?i)^\border\s+by\b"#, options: .regularExpression) != nil {
                return text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BoardSwimlaneSettings: Sendable {
    public let lanes: [BoardSwimlane]
    public let completedIssuesCutoff: String?
    public let kanbanBacklogEnabled: Bool
    public let response: Data
}

extension JiraClient {
    public func boardSwimlanes(site: JiraSite, token: String, boardID: Int) async throws -> BoardSwimlaneSettings {
        do {
            return try await boardSwimlanes(site: site, token: token, boardID: boardID, compact: true)
        } catch is DecodingError {
            // Older deployments may not include the base settings in a projected response.
        } catch JiraError.invalidResponse {
        } catch JiraError.queryRejected {
        } catch JiraError.httpStatus(400) {
        }
        try Task.checkCancellation()
        return try await boardSwimlanes(site: site, token: token, boardID: boardID, compact: false)
    }

    private func boardSwimlanes(site: JiraSite, token: String, boardID: Int, compact: Bool) async throws -> BoardSwimlaneSettings {
        // Jira's public Agile configuration omits swimlanes. This read-only endpoint is also used by its web UI.
        var query = [URLQueryItem(name: "rapidViewId", value: String(boardID))]
        if compact { query.append(URLQueryItem(name: "expand", value: "workingDaysConfig")) }
        let data = try await fetch("rapidviewconfig/editmodel.json", site: site, token: token,
                                   queryItems: query, greenhopper: true)
        struct Response: Decodable {
            let swimlanesConfig: SwimlaneConfiguration
            let oldDoneIssuesCutoff: String?
            let isKanPlanEnabled: Bool?
        }
        let response: Response = try decode(data)
        guard response.swimlanesConfig.rapidViewId == boardID else { throw JiraError.invalidResponse }
        if compact {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard object?["oldDoneIssuesCutoff"] != nil, object?["isKanPlanEnabled"] != nil else {
                throw JiraError.invalidResponse
            }
        }
        let cutoff = response.oldDoneIssuesCutoff.flatMap { $0 == "NONE" ? nil : $0 }
        if let cutoff, cutoff.range(of: #"^-[1-9][0-9]*[wd]$"#, options: .regularExpression) == nil {
            throw BoardSwimlaneError.invalidConfiguration
        }
        return BoardSwimlaneSettings(lanes: try response.swimlanesConfig.lanes(), completedIssuesCutoff: cutoff,
                                    kanbanBacklogEnabled: response.isKanPlanEnabled ?? false, response: data)
    }
}
