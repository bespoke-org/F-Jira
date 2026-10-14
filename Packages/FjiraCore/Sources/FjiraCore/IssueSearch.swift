import Foundation

public struct JiraProject: Codable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let avatarUrls: [String: URL]?

    public var avatarURL: URL? {
        guard let avatarUrls else { return nil }
        return avatarUrls["48x48"] ?? avatarUrls["32x32"] ?? avatarUrls["24x24"]
            ?? avatarUrls["16x16"] ?? avatarUrls.sorted { $0.key < $1.key }.first?.value
    }
}

public struct CachedProjects: Codable, Sendable {
    public let projects: [JiraProject]
    public let fetchedAt: Date
    public let response: Data
}

public struct ProjectQuery: Codable, Hashable, Sendable {
    public let projectID: String
    public let input: String
    public let jql: String

    public init(projectID: String, input: String) throws {
        guard !projectID.isEmpty, projectID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SearchError.invalidProject
        }
        let savedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = projectID
        self.input = savedInput
        guard let input = Self.jqlInput(from: savedInput) else {
            let text = Self.plainText(from: savedInput)
            let filter = text.isEmpty ? "" : " AND (summary ~ \(Self.textLiteral(text)) OR description ~ \(Self.textLiteral(text)))"
            jql = "project = \(projectID)\(filter) ORDER BY updated DESC, key ASC"
            return
        }
        let expression = try NSRegularExpression(pattern: #"\border\s+by\b"#, options: .caseInsensitive)
        let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
        let ranges = matches.compactMap { Range($0.range, in: input) }
        var orderRanges: [Range<String.Index>] = []
        var depth = 0
        var quote: Character?
        var escaped = false
        for index in input.indices {
            let character = input[index]
            if escaped { escaped = false; continue }
            if quote != nil {
                if character == "\\" { escaped = true }
                else if character == quote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            guard depth >= 0 else { throw SearchError.unbalancedQuery }
            if depth == 0, let range = ranges.first(where: { $0.lowerBound == index }) {
                orderRanges.append(range)
            }
        }
        guard quote == nil, depth == 0 else { throw SearchError.unbalancedQuery }
        guard orderRanges.count <= 1 else { throw SearchError.multipleOrderClauses }
        let filter: String
        let ordering: String
        if let range = orderRanges.first {
            filter = String(input[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SearchError.missingSortField
            }
            ordering = String(input[range.lowerBound...])
        } else {
            filter = input
            ordering = "ORDER BY updated DESC, key ASC"
        }
        jql = "project = \(projectID)" + (filter.isEmpty ? "" : " AND (\(filter))") + " \(ordering)"
    }

    /// The original text for a normal search, or nil when the input is JQL.
    public var searchText: String? {
        Self.jqlInput(from: input) == nil ? Self.plainText(from: input) : nil
    }

    private static func plainText(from input: String) -> String {
        let text = input.lowercased().hasPrefix("text:") ? String(input.dropFirst(5)) : input
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jqlInput(from input: String) -> String? {
        if input.lowercased().hasPrefix("text:") { return nil }
        if input.lowercased().hasPrefix("jql:") {
            return String(input.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if input.isEmpty { return input }
        let prefix = #"(?i)^(?:(?:NOT\b|!)\s*|\(\s*)*"#
        let field = #"(?:"(?:\\.|[^"\\])+"|'(?:\\.|[^'\\])+'|cf\[\d+\]|[\p{L}_][\p{L}\p{N}_.]*)"#
        let patterns = [
            #"(?i)^ORDER\s+BY\b"#,
            prefix + field + #"\s*(?:!=|!~|>=|<=|=|~|>|<)"#,
            prefix + field + #"\s+(?:(?:NOT\s+)?IN\s*(?:\(|[\w]+\s*\()|IS\s+(?:NOT\s+)?(?:EMPTY|NULL)\b)"#,
            prefix + #"(?:assignee|fixVersion|priority|reporter|resolution|status)\s+(?:WAS|CHANGED)\b"#
        ]
        return patterns.contains { input.range(of: $0, options: .regularExpression) != nil } ? input : nil
    }

    private static func textLiteral(_ input: String) -> String {
        // Jira text searches are case-insensitive. Lowercase also prevents Lucene's AND/OR/NOT operators.
        let text = input.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let reserved = Set(#"+-&|!(){}[]^"~*?:\/"#)
        let lucene = text.map { reserved.contains($0) ? "\\" + String($0) : String($0) }.joined()
        // Escape Lucene first, then the surrounding JQL string. JSON encoding is handled by the client.
        let escaped = lucene.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

public enum SearchError: LocalizedError, Equatable {
    case invalidProject, unbalancedQuery, multipleOrderClauses, missingSortField, inconsistentPagination

    public var errorDescription: String? {
        switch self {
        case .invalidProject: "Select a valid Jira project."
        case .unbalancedQuery: "Check the matching parentheses and quotation marks in your JQL."
        case .multipleOrderClauses: "Use a single ORDER BY clause at the end of your JQL."
        case .missingSortField: "Add a field after ORDER BY, such as updated DESC."
        case .inconsistentPagination: "The search results changed while loading pages. Run the search again."
        }
    }
}

public struct JiraIssue: Codable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let fields: Fields

    public struct Fields: Codable, Sendable {
        public let summary: String?
        public let status: NamedValue?
        public let assignee: JiraUser?
        public let priority: NamedValue?
        public let updated: String?
        public let issuetype: NamedValue?
    }

    public struct NamedValue: Codable, Sendable {
        public let name: String
        public let id: String?
        public let iconUrl: URL?
        public let statusCategory: JiraStatusCategory?
    }

    public var summary: String { fields.summary ?? "" }
    public var status: String { fields.status?.name ?? "—" }
    public var statusSortKey: JiraStatusSortKey {
        JiraStatusSortKey(name: fields.status?.name, category: fields.status?.statusCategory)
    }
    public var statusTone: JiraStatusTone { fields.status?.statusCategory?.tone ?? .neutral }
    public var assignee: String { fields.assignee?.displayName ?? "Unassigned" }
    public var priority: String { fields.priority?.name ?? "—" }
    public var issueType: String { fields.issuetype?.name ?? "—" }
    public var updated: Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return fields.updated.flatMap(formatter.date(from:)) ?? .distantPast
    }
}

public struct IssuePage: Codable, Sendable {
    public let startAt: Int
    public let maxResults: Int
    public let total: Int?
    public let issues: [JiraIssue]
    public let warningMessages: [String]?
}

public struct CachedIssuePage: Codable, Sendable {
    public let page: IssuePage
    public let response: Data
    public let fetchedAt: Date
}

public struct CachedSearch: Codable, Sendable {
    public let query: ProjectQuery
    public let generation: UUID
    public var pages: [CachedIssuePage]

    var restoringMetadata: CachedSearch {
        var restored = self
        restored.pages = pages.map { cached in
            guard cached.page.issues.contains(where: {
                $0.fields.status?.statusCategory == nil || $0.fields.issuetype?.iconUrl == nil
                    || $0.fields.priority?.iconUrl == nil || $0.fields.assignee?.avatarURL == nil
            }),
                  let original = try? JSONDecoder().decode(IssuePage.self, from: cached.response),
                  original.startAt == cached.page.startAt,
                  original.issues.map(\.id) == cached.page.issues.map(\.id),
                  original.issues.map(\.key) == cached.page.issues.map(\.key),
                  zip(cached.page.issues, original.issues).contains(where: { old, new in
                      (old.fields.status?.statusCategory == nil && new.fields.status?.statusCategory != nil)
                        || (old.fields.issuetype?.iconUrl == nil && new.fields.issuetype?.iconUrl != nil)
                        || (old.fields.priority?.iconUrl == nil && new.fields.priority?.iconUrl != nil)
                        || (old.fields.assignee?.avatarURL == nil && new.fields.assignee?.avatarURL != nil)
                  }) else { return cached }
            return CachedIssuePage(page: original, response: cached.response, fetchedAt: cached.fetchedAt)
        }
        return restored
    }

    public var issues: [JiraIssue] {
        var seen = Set<String>()
        return pages.flatMap(\.page.issues).filter { seen.insert($0.id).inserted }
    }
    public var issueTypeIconURLs: [URL] {
        var seen = Set<URL>()
        return issues.compactMap { $0.fields.issuetype?.iconUrl }.filter { seen.insert($0).inserted }
    }
    public var tableImageURLs: [URL] {
        var seen = Set<URL>()
        let metadata = issueTypeIconURLs + issues.compactMap { $0.fields.priority?.iconUrl }
        return (metadata + issues.compactMap { $0.fields.assignee?.avatarURL }).filter { seen.insert($0).inserted }
    }
    public var total: Int? { pages.last?.page.total }
    public var nextStartAt: Int { pages.last.map { $0.page.startAt + $0.page.issues.count } ?? 0 }
    public var fetchedAt: Date { pages.first?.fetchedAt ?? .distantPast }
    public var hasMore: Bool {
        guard let last = pages.last, !last.page.issues.isEmpty else { return false }
        if let total { return nextStartAt < total }
        return last.page.issues.count >= last.page.maxResults
    }
}

extension JiraClient {
    public func projects(site: JiraSite, token: String) async throws -> CachedProjects {
        let data = try await fetch("project", site: site, token: token)
        let projects: [JiraProject] = try decode(data)
        return CachedProjects(projects: projects, fetchedAt: Date(), response: data)
    }

    public func search(
        site: JiraSite, token: String, query: ProjectQuery, startAt: Int = 0
    ) async throws -> CachedIssuePage {
        struct Request: Encodable {
            let jql: String
            let startAt: Int
            let maxResults = 50
            let validateQuery = true
            let fields = ["summary", "status", "assignee", "priority", "updated", "issuetype", "project"]
        }
        guard startAt >= 0 else { throw SearchError.inconsistentPagination }
        let body = try JSONEncoder().encode(Request(jql: query.jql, startAt: startAt))
        let data = try await fetch("search", site: site, token: token, body: body)
        let page: IssuePage = try decode(data)
        guard page.startAt == startAt, page.maxResults > 0,
              page.total.map({ $0 >= 0 }) ?? true,
              !(page.issues.isEmpty && (page.total ?? 0) > startAt) else {
            throw SearchError.inconsistentPagination
        }
        return CachedIssuePage(page: page, response: data, fetchedAt: Date())
    }
}
