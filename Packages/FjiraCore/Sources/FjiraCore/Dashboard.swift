import Foundation

public enum DashboardSection: String, CaseIterable, Codable, Sendable {
    case myIssues, upNext, recentlyDone

    public var title: String {
        switch self {
        case .myIssues: "Current Issues"
        case .upNext: "Up next"
        case .recentlyDone: "Recently done"
        }
    }

    public func query(projectID: String, configuration: DashboardConfiguration) throws -> ProjectQuery {
        let filter: String
        switch self {
        case .myIssues: filter = #"statusCategory != Done AND status NOT IN ("New", "Backlog") ORDER BY priority DESC, updated DESC"#
        case .upNext: filter = #"(statusCategory = "To Do" OR status IN ("New", "Backlog")) ORDER BY priority DESC, created ASC"#
        case .recentlyDone: filter = "statusCategory = Done AND resolved >= -14d ORDER BY resolved DESC"
        }
        return try ProjectQuery(projectID: projectID, input: "jql: \(configuration.ownershipJQL) AND \(filter)")
    }
}

public enum DashboardCommentScope: String, CaseIterable, Codable, Sendable {
    case mine, project
    public var title: String { self == .mine ? "My" : "All" }
}

public struct DashboardConfiguration: Codable, Sendable {
    public let implementerFields: [String]
    public let response: Data
    public let fetchedAt: Date

    public var ownershipJQL: String {
        let implementers = implementerFields.map { "cf[\($0.dropFirst("customfield_".count))] = currentUser()" }
        return "(" + (["assignee = currentUser()"] + implementers).joined(separator: " OR ") + ")"
    }

    static func decode(_ data: Data) throws -> DashboardConfiguration {
        struct Field: Decodable { let id: String; let name: String }
        let fields = try JSONDecoder().decode([Field].self, from: data)
        let ids = fields.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "implementer"
                && $0.id.range(of: #"^customfield_[0-9]+$"#, options: .regularExpression) != nil
        }.map(\.id).sorted()
        return DashboardConfiguration(implementerFields: ids, response: data, fetchedAt: Date())
    }
}

public struct DashboardComment: Codable, Identifiable, Sendable {
    public var issue: JiraIssue
    public let comment: JiraComment
    public var id: String { issue.key + ":" + comment.id }
    public let date: Date

    public init(issue: JiraIssue, comment: JiraComment) {
        self.issue = issue
        self.comment = comment
        self.date = DashboardDate.parse(comment.created) ?? .distantPast
    }
    public var preview: String {
        (comment.body ?? "Open this issue to read the comment.").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct DashboardCommentPage: Codable, Sendable {
    public let issues: CachedIssuePage
    public let comments: [DashboardComment]
    public let extraPages: [String: [CachedCommentPage]]
}

public struct CachedDashboardComments: Codable, Sendable {
    public let scope: DashboardCommentScope
    public var pages: [DashboardCommentPage]
    public let since: Date
    public var fetchedAt: Date { pages.first?.issues.fetchedAt ?? .distantPast }
    public var nextStartAt: Int { pages.last.map { $0.issues.page.startAt + $0.issues.page.issues.count } ?? 0 }
    public var comments: [DashboardComment] {
        var seen = Set<String>()
        return pages.flatMap(\.comments).filter { $0.date >= since && seen.insert($0.id).inserted }
            .sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    }
    public var needsMoreIssues: Bool {
        guard let last = pages.last?.issues.page, !last.issues.isEmpty,
              nextStartAt < (last.total ?? Int.max) else { return false }
        let latest = comments
        // An older issue cannot contain a comment newer than its own updated time.
        return latest.count < 20 || (last.issues.last?.revision ?? .distantFuture) >= latest[19].date
    }
    public var imageURLs: [URL] { comments.prefix(20).compactMap { $0.comment.author?.avatarURL } }
}

public struct ViewedIssue: Codable, Identifiable, Sendable {
    public var issue: JiraIssue
    public let viewedAt: Date
    public var id: String { issue.key }
}

enum DashboardDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension JiraClient {
    public func dashboardConfiguration(site: JiraSite, token: String) async throws -> DashboardConfiguration {
        try DashboardConfiguration.decode(await fetch("field", site: site, token: token))
    }

    public func dashboardCommentPage(site: JiraSite, token: String, projectID: String,
                                     scope: DashboardCommentScope, configuration: DashboardConfiguration,
                                     startAt: Int) async throws -> DashboardCommentPage {
        let ownership = scope == .mine ? configuration.ownershipJQL + " AND " : ""
        let query = try ProjectQuery(projectID: projectID, input: "jql: \(ownership)updated >= -7d ORDER BY updated DESC, key ASC")
        struct Request: Encodable {
            let jql: String
            let startAt: Int
            let maxResults = 50
            let fields = ["summary", "status", "assignee", "priority", "updated", "issuetype", "comment"]
            let expand = ["names"]
        }
        guard startAt >= 0 else { throw SearchError.inconsistentPagination }
        let response = try await fetch("search", site: site, token: token,
                                       body: JSONEncoder().encode(Request(jql: query.jql, startAt: startAt)))
        let page: IssuePage = try decode(response)
        guard page.startAt == startAt, page.maxResults > 0,
              !(page.issues.isEmpty && (page.total ?? 0) > startAt) else { throw SearchError.inconsistentPagination }
        struct CommentResponse: Decodable {
            let issues: [Issue]
            struct Issue: Decodable {
                let id: String
                let fields: Fields
                struct Fields: Decodable { let comment: CommentPage? }
            }
        }
        let details: CommentResponse = try decode(response)
        var comments: [DashboardComment] = []
        var extra: [String: [CachedCommentPage]] = [:]
        let known = Dictionary(page.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in details.issues {
            guard let issue = known[item.id], let commentPage = item.fields.comment else { continue }
            var values = commentPage.comments
            if let total = commentPage.total, commentPage.nextStartAt < total {
                // Some Server versions truncate comments in search responses. Fetch the latest page only.
                var offset = max(0, total - 50)
                values = []
                // Respect servers that cap comment pages below the requested 50.
                while offset < total {
                    let tail = try await self.comments(site: site, token: token, id: item.id, startAt: offset)
                    extra[item.id, default: []].append(tail)
                    values += tail.page.comments
                    guard tail.page.nextStartAt > offset else { break }
                    offset = tail.page.nextStartAt
                    if offset >= (tail.page.total ?? total) { break }
                }
            }
            comments += values.map { DashboardComment(issue: issue, comment: $0) }
        }
        return DashboardCommentPage(issues: CachedIssuePage(page: page, response: response, fetchedAt: Date()),
                                    comments: comments, extraPages: extra)
    }
}
