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
            let images = try Self.cachedImages(in: db, site: site, account: account, urls: urls)
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
        var data = try Data.fetchOne(db,
            sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
            arguments: [site, account, "issue-detail:\(id)"])
        if data == nil, id.contains("-") {
            data = try Data.fetchOne(db, sql: """
                SELECT payload FROM response_cache
                WHERE site = ? AND account = ? AND resource LIKE 'issue-detail:%'
                AND json_extract(CAST(payload AS TEXT), '$.issue.key') = ?
                LIMIT 1
                """, arguments: [site, account, id])
        }
        guard let data else { return nil }
        let saved = try JSONDecoder().decode(CachedIssueDetail.self, from: data)
        // Recover metadata added after the original snapshot was saved from the complete response.
        // Recover the immutable issue fields without losing cached pages or remote links.
        guard saved.issue.fields.issuetype?.iconUrl == nil || saved.issue.fields.priority?.iconUrl == nil
                || saved.issue.fields.status?.statusCategory == nil || saved.issue.epicLink == nil
                || !saved.issue.hasImplementerField || saved.issue.implementer == nil,
              let original = try? JSONDecoder().decode(JiraIssueDetail.self, from: saved.response),
              original.id == saved.issue.id, original.key == saved.issue.key,
              (saved.issue.fields.issuetype?.iconUrl == nil && original.fields.issuetype?.iconUrl != nil)
                || (saved.issue.fields.priority?.iconUrl == nil && original.fields.priority?.iconUrl != nil)
                || (saved.issue.fields.status?.statusCategory == nil && original.fields.status?.statusCategory != nil)
                || (saved.issue.epicLink == nil && original.epicLink != nil)
                || (!saved.issue.hasImplementerField && original.hasImplementerField)
                || (saved.issue.implementer == nil && original.implementer != nil) else { return saved }
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
