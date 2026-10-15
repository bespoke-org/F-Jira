import Foundation

public struct JiraIssueDetail: Codable, Sendable {
    public let id: String
    public let key: String
    public internal(set) var fields: Fields
    public let renderedFields: RenderedFields?
    public let epicLink: JiraEpicLink?
    public let implementer: JiraUser?
    public let hasImplementerField: Bool

    private enum CodingKeys: String, CodingKey { case id, key, fields, renderedFields, epicLink, implementer, hasImplementerField }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        key = try values.decode(String.self, forKey: .key)
        fields = try values.decode(Fields.self, forKey: .fields)
        renderedFields = try values.decodeIfPresent(RenderedFields.self, forKey: .renderedFields)
        epicLink = (try? values.decodeIfPresent(JiraEpicLink.self, forKey: .epicLink)) ?? JiraEpicLink.decode(from: decoder)
        let custom = Self.decodeImplementer(from: decoder)
        implementer = (try? values.decodeIfPresent(JiraUser.self, forKey: .implementer)) ?? custom.user
        hasImplementerField = (try? values.decode(Bool.self, forKey: .hasImplementerField))
            ?? (custom.isPresent || implementer != nil)
    }

    private static func decodeImplementer(from decoder: any Decoder) -> (user: JiraUser?, isPresent: Bool) {
        guard let root = try? decoder.container(keyedBy: FieldKey.self),
              let names = try? root.decode([String: String].self, forKey: FieldKey("names")),
              let fields = try? root.nestedContainer(keyedBy: FieldKey.self, forKey: FieldKey("fields")) else { return (nil, false) }
        let keys = names.keys.filter {
            names[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "implementer"
                && fields.contains(FieldKey($0))
        }.sorted()
        let user = keys.lazy.compactMap { try? fields.decode(JiraUser.self, forKey: FieldKey($0)) }.first
        return (user, !keys.isEmpty)
    }

    public struct Fields: Codable, Sendable {
        public let summary: String?
        public let description: String?
        public let status: JiraIssue.NamedValue?
        public let assignee: JiraUser?
        public let reporter: JiraUser?
        public let priority: JiraIssue.NamedValue?
        public let issuetype: JiraIssue.NamedValue?
        public let resolution: JiraIssue.NamedValue?
        public let created: String?
        public let updated: String?
        public let duedate: String?
        public let labels: [String]?
        public let components: [JiraIssue.NamedValue]?
        public let fixVersions: [JiraIssue.NamedValue]?
        public let comment: CommentPage?
        public let subtasks: [JiraIssue]?
        public let issuelinks: [IssueLink]?
        public let attachment: [IssueAttachment]?
    }

    public struct RenderedFields: Codable, Sendable {
        public let description: String?
        public let comment: CommentPage?

        private enum CodingKeys: String, CodingKey { case description, comment }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            description = try? values.decode(String.self, forKey: .description)
            comment = try? values.decode(CommentPage.self, forKey: .comment)
        }
    }

    public var listIssue: JiraIssue {
        JiraIssue(id: id, key: key, fields: .init(
            summary: fields.summary, status: fields.status, assignee: fields.assignee,
            priority: fields.priority, updated: fields.updated, issuetype: fields.issuetype
        ))
    }
}

public struct JiraComment: Codable, Identifiable, Sendable {
    public let id: String
    public let body: String?
    public let renderedBody: String?
    public let author: Author?
    public let created: String?
    public let updated: String?

    public struct Author: Codable, Sendable {
        public let displayName: String?
        public let name: String?
        public let avatarUrls: [String: URL]?

        public var avatarURL: URL? {
            ["48x48", "32x32", "24x24", "16x16"].compactMap { avatarUrls?[$0] }.first
                ?? avatarUrls?.sorted { $0.key < $1.key }.first?.value
        }
    }

    public var authorName: String {
        for value in [author?.displayName, author?.name] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return "Unknown author"
    }
}

public struct CommentPage: Codable, Sendable {
    public let startAt: Int?
    public let maxResults: Int?
    public let total: Int?
    public let comments: [JiraComment]
    public var nextStartAt: Int { (startAt ?? 0) + comments.count }
}

public struct IssueLink: Codable, Identifiable, Sendable {
    public let id: String
    public let type: LinkType
    public let inwardIssue: JiraIssue?
    public let outwardIssue: JiraIssue?

    public struct LinkType: Codable, Sendable {
        public let name: String?
        public let inward: String?
        public let outward: String?
    }

    public var relatedIssue: JiraIssue? { outwardIssue ?? inwardIssue }
    public var label: String {
        (outwardIssue != nil ? type.outward : type.inward) ?? type.name ?? "Related"
    }
}

public struct IssueAttachment: Codable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let size: Int?
    public let mimeType: String?
    public let content: URL?
}

public struct CachedCommentPage: Codable, Sendable {
    public let page: CommentPage
    public let response: Data
    public let fetchedAt: Date
}

public struct CachedIssueDetail: Codable, Sendable {
    public internal(set) var issue: JiraIssueDetail
    public let response: Data
    public let fetchedAt: Date
    public let generation: UUID
    public var commentPages: [CachedCommentPage]
    public var previousComments: [JiraComment]
    public var remoteLinks: CachedRemoteIssueLinks? = nil

    var imageURLs: [URL] {
        let fields = issue.fields
        let metadata = [fields.issuetype?.iconUrl, fields.priority?.iconUrl,
                        fields.assignee?.avatarURL, issue.implementer?.avatarURL, fields.reporter?.avatarURL].compactMap { $0 }
        var seen = Set<URL>()
        return (metadata + comments.compactMap { $0.author?.avatarURL }).filter { seen.insert($0).inserted }
    }

    func imageURLs(baseURL: URL) -> [URL] {
        let rendered = ([issue.renderedFields?.description] + comments.map { renderedBody(for: $0) }).compactMap { $0 }
        var seen = Set<URL>()
        return (imageURLs + rendered.flatMap { JiraRichTextImages.urls(in: $0, baseURL: baseURL) })
            .filter { seen.insert($0).inserted }
    }

    public var currentComments: [JiraComment] {
        var seen = Set<String>()
        return ((issue.fields.comment?.comments ?? []) + commentPages.flatMap(\.page.comments))
            .filter { seen.insert($0.id).inserted }
    }
    public var comments: [JiraComment] {
        var seen = Set<String>()
        return (currentComments + previousComments).filter { seen.insert($0.id).inserted }
    }
    public var hasPreviousComments: Bool { comments.count > currentComments.count }
    public var totalComments: Int? { commentPages.last?.page.total ?? issue.fields.comment?.total }
    public var nextCommentStartAt: Int { commentPages.last?.page.nextStartAt ?? issue.fields.comment?.nextStartAt ?? 0 }
    public var hasMoreComments: Bool { totalComments.map { nextCommentStartAt < $0 } ?? false }

    public func renderedBody(for comment: JiraComment) -> String? {
        comment.renderedBody ?? issue.renderedFields?.comment?.comments.first { $0.id == comment.id }?.body
    }
}

extension JiraClient {
    public func issue(site: JiraSite, token: String, id: String) async throws -> CachedIssueDetail {
        guard Self.validIssueIdentifier(id) else { throw JiraError.invalidResponse }
        let response = try await fetch("issue/\(id)", site: site, token: token,
                                       queryItems: [URLQueryItem(name: "expand", value: "renderedFields,names,schema")])
        let issue: JiraIssueDetail = try decode(response)
        return CachedIssueDetail(issue: issue, response: response, fetchedAt: Date(), generation: UUID(), commentPages: [], previousComments: [])
    }

    public func comments(site: JiraSite, token: String, id: String, startAt: Int) async throws -> CachedCommentPage {
        guard Self.validIssueIdentifier(id), startAt >= 0 else { throw JiraError.invalidResponse }
        let response = try await fetch("issue/\(id)/comment", site: site, token: token, queryItems: [
            URLQueryItem(name: "startAt", value: String(startAt)),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "expand", value: "renderedBody")
        ])
        let page: CommentPage = try decode(response)
        guard page.startAt == startAt,
              !(page.comments.isEmpty && (page.total ?? 0) > startAt) else { throw SearchError.inconsistentPagination }
        return CachedCommentPage(page: page, response: response, fetchedAt: Date())
    }

    static func validIssueIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
