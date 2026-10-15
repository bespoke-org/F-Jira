import Foundation
import GRDB

public enum IssueActivityTab: String, Sendable { case comments, history }

public struct JiraHistoryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let author: JiraComment.Author?
    public let created: String?
    public let items: [Change]

    public var authorName: String { author?.displayName ?? author?.name ?? "Unknown author" }

    public struct Change: Codable, Sendable {
        public let field: String
        public let from: String?
        public let fromString: String?
        public let to: String?
        public let toString: String?
    }
}

public struct CachedIssueHistory: Codable, Sendable {
    public let entries: [JiraHistoryEntry]
    public let total: Int
    public let response: Data
    public let fetchedAt: Date

    public var newestFirst: [JiraHistoryEntry] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        return entries.map { entry in
            (entry, entry.created.flatMap { formatter.date(from: $0) ?? seconds.date(from: $0) } ?? .distantPast)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id.compare($1.0.id, options: .numeric) == .orderedDescending
        }.map(\.0)
    }
}

extension JiraClient {
    public func issueHistory(site: JiraSite, token: String, id: String) async throws -> CachedIssueHistory {
        guard Self.validIssueIdentifier(id) else { throw JiraError.invalidResponse }
        // Server/Data Center exposes history through issue expansion, not Cloud's changelog endpoint.
        let response = try await fetch("issue/\(id)", site: site, token: token, queryItems: [
            URLQueryItem(name: "fields", value: "summary"),
            URLQueryItem(name: "expand", value: "changelog")
        ])
        struct Response: Decodable {
            let id: String
            let key: String
            let changelog: Changelog
            struct Changelog: Decodable {
                let startAt: Int
                let total: Int
                let histories: [JiraHistoryEntry]
            }
        }
        let result: Response = try decode(response)
        guard result.id == id || result.key == id,
              result.changelog.startAt >= 0, result.changelog.total >= result.changelog.histories.count else {
            throw JiraError.invalidResponse
        }
        var seen = Set<String>()
        let entries = result.changelog.histories.filter { seen.insert($0.id).inserted }
        return CachedIssueHistory(entries: entries, total: result.changelog.total, response: response, fetchedAt: Date())
    }
}

extension ConnectionCache {
    public func saveIssueHistory(_ history: CachedIssueHistory, site: String, account: String,
                                 id: String, expectedGeneration: UUID) throws {
        try database.write { db in
            guard var detail = try Self.readDetail(in: db, site: site, account: account, id: id),
                  detail.generation == expectedGeneration else { throw SearchError.inconsistentPagination }
            detail.history = history
            try Self.writeDetail(detail, in: db, site: site, account: account)
        }
    }
}
