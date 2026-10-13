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
        return try JSONDecoder().decode(CachedIssueDetail.self, from: data)
    }

    static func writeDetail(_ detail: CachedIssueDetail, in db: Database, site: String, account: String) throws {
        try db.execute(sql: """
            INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
            """, arguments: [site, account, "issue-detail:\(detail.issue.id)", try JSONEncoder().encode(detail)])
    }
}
