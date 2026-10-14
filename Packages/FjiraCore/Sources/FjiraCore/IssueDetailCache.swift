import Foundation
import GRDB

extension ConnectionCache {
    public func saveIssue(_ detail: CachedIssueDetail, site: String, account: String) throws {
        try database.write { db in
            // Keep a complete detail response separate from the smaller search-list projection.
            var snapshot = detail
            if let previous = try Self.readDetail(in: db, site: site, account: account, id: detail.issue.id) {
                snapshot.remoteLinks = detail.remoteLinks ?? previous.remoteLinks
                if detail.hasMoreComments {
                    let currentIDs = Set(detail.currentComments.map(\.id))
                    snapshot.previousComments = previous.comments.filter { !currentIDs.contains($0.id) }
                }
            }
            try Self.writeDetail(snapshot, in: db, site: site, account: account)
        }
    }

    public func loadIssue(site: String, account: String, id: String) throws -> CachedIssueDetail? {
        try database.read { db in try Self.readDetail(in: db, site: site, account: account, id: id) }
    }

    func loadIssuePresentation(site: String, account: String, id: String) throws
        -> (detail: CachedIssueDetail, images: [String: CachedAvatar])? {
        try database.read { db in
            guard let detail = try Self.readDetail(in: db, site: site, account: account, id: id) else { return nil }
            let urls = URL(string: site).map { detail.imageURLs(baseURL: $0) } ?? detail.imageURLs
            var images: [String: CachedAvatar] = [:]
            for offset in stride(from: 0, to: urls.count, by: 200) {
                let resources = urls[offset..<min(offset + 200, urls.count)].map { "avatar:\($0.absoluteString)" }
                let placeholders = Array(repeating: "?", count: resources.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT resource, payload FROM response_cache
                    WHERE site = ? AND account = ? AND resource IN (\(placeholders))
                    """, arguments: StatementArguments([site, account] + resources))
                for row in rows {
                    let resource: String = row["resource"]
                    let data: Data = row["payload"]
                    if let image = try? JSONDecoder().decode(CachedAvatar.self, from: data) {
                        images[String(resource.dropFirst("avatar:".count))] = image
                    }
                }
            }
            return (detail, images)
        }
    }

    public func saveComments(
        _ page: CachedCommentPage, site: String, account: String, id: String, expectedGeneration: UUID
    ) throws {
        try database.write { db in
            guard var detail = try Self.readDetail(in: db, site: site, account: account, id: id),
                  detail.generation == expectedGeneration,
                  detail.nextCommentStartAt == page.page.startAt else { throw SearchError.inconsistentPagination }
            detail.commentPages.append(page)
            if !detail.hasMoreComments { detail.previousComments = [] }
            try Self.writeDetail(detail, in: db, site: site, account: account)
            try db.execute(sql: """
                INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                """, arguments: [site, account, "issue-comments:\(id):\(page.page.startAt ?? 0)", page.response])
        }
    }

    static func readDetail(in db: Database, site: String, account: String, id: String) throws -> CachedIssueDetail? {
        guard let data = try Data.fetchOne(db,
            sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
            arguments: [site, account, "issue-detail:\(id)"]) else { return nil }
        let saved = try JSONDecoder().decode(CachedIssueDetail.self, from: data)
        // Older projections omitted icon URLs and status categories, but the full response kept them.
        // Recover the immutable issue fields without losing cached pages or remote links.
        guard saved.issue.fields.issuetype?.iconUrl == nil || saved.issue.fields.priority?.iconUrl == nil
                || saved.issue.fields.status?.statusCategory == nil,
              let original = try? JSONDecoder().decode(JiraIssueDetail.self, from: saved.response),
              original.id == saved.issue.id, original.key == saved.issue.key,
              (saved.issue.fields.issuetype?.iconUrl == nil && original.fields.issuetype?.iconUrl != nil)
                || (saved.issue.fields.priority?.iconUrl == nil && original.fields.priority?.iconUrl != nil)
                || (saved.issue.fields.status?.statusCategory == nil && original.fields.status?.statusCategory != nil) else { return saved }
        var recovered = CachedIssueDetail(issue: original, response: saved.response, fetchedAt: saved.fetchedAt,
                                          generation: saved.generation, commentPages: saved.commentPages,
                                          previousComments: saved.previousComments)
        recovered.remoteLinks = saved.remoteLinks
        return recovered
    }

    static func writeDetail(_ detail: CachedIssueDetail, in db: Database, site: String, account: String) throws {
        try db.execute(sql: """
            INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
            """, arguments: [site, account, "issue-detail:\(detail.issue.id)", try JSONEncoder().encode(detail)])
    }
}
