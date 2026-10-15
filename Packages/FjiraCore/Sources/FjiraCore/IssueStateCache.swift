import Foundation
import GRDB

struct KnownIssue: Codable {
    let issue: JiraIssue
    let verified: Bool

    func accepting(_ candidate: KnownIssue) -> KnownIssue {
        let prefer = candidate.verified || !verified
        let winner = issue.prefers(candidate.issue, onEqual: prefer) ? candidate : self
        return KnownIssue(issue: issue.accepting(candidate.issue, onEqual: prefer), verified: winner.verified)
    }
}

extension ConnectionCache {
    /// Persist shared issue fields independently of query membership and pagination.
    func reconcileIssues(_ issues: [JiraIssue], site: String, account: String, verified: Bool = false) throws
        -> (issues: [JiraIssue], conflicts: [JiraIssue]) {
        try database.write { db in
            try Self.mergeIssues(issues, in: db, site: site, account: account, verified: verified)
        }
    }

    static func mergeIssues(_ issues: [JiraIssue], in db: Database, site: String, account: String,
                            verified: Bool = false) throws -> (issues: [JiraIssue], conflicts: [JiraIssue]) {
        let receivedEpics = Dictionary(issues.compactMap(\.epicLink).filter(\.hasPresentation).map { ($0.key, $0) },
                                       uniquingKeysWith: { _, latest in latest })
        for epic in receivedEpics.values {
            try writeEpic(CachedJiraEpic(epic: epic, response: try JSONEncoder().encode(epic), fetchedAt: Date()),
                          in: db, site: site, account: account)
        }
        var known = try knownIssues(issues.map(\.id), in: db, site: site, account: account)
        var conflicts: [JiraIssue] = []
        for issue in issues {
            let candidate = KnownIssue(issue: issue, verified: verified)
            if let old = known[issue.id], let status = old.issue.statusIdentity,
               let received = issue.statusIdentity, status != received {
                conflicts.append(issue)
            }
            known[issue.id] = known[issue.id]?.accepting(candidate) ?? candidate
        }
        for value in known.values {
            try db.execute(sql: """
                INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                """, arguments: [site, account, "issue-current:\(value.issue.id)", try JSONEncoder().encode(value)])
        }
        return (JiraIssue.newest(issues).compactMap { known[$0.id]?.issue }, JiraIssue.newest(conflicts))
    }

    /// Include pre-existing full details and list responses when upgrading an older cache.
    static func knownIssues(_ ids: [String], in db: Database, site: String, account: String) throws -> [String: KnownIssue] {
        let ids = Array(Set(ids))
        var result: [String: KnownIssue] = [:]
        for offset in stride(from: 0, to: ids.count, by: 200) {
            let resources = ids[offset..<min(offset + 200, ids.count)].flatMap {
                ["issue-current:\($0)", "issue-detail:\($0)", "issue-list:\($0)"]
            }
            let placeholders = Array(repeating: "?", count: resources.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT resource, payload FROM response_cache WHERE site = ? AND account = ?
                AND resource IN (\(placeholders)) ORDER BY resource
                """, arguments: StatementArguments([site, account] + resources))
            for row in rows {
                let resource: String = row["resource"]
                let data: Data = row["payload"]
                let value: KnownIssue
                if resource.hasPrefix("issue-current:") {
                    value = try JSONDecoder().decode(KnownIssue.self, from: data)
                } else if resource.hasPrefix("issue-detail:") {
                    let detail = try JSONDecoder().decode(CachedIssueDetail.self, from: data)
                    let original = try? JSONDecoder().decode(JiraIssueDetail.self, from: detail.response)
                    let issue = original.map { detail.issue.listIssue.accepting($0.listIssue, onEqual: false) } ?? detail.issue.listIssue
                    value = KnownIssue(issue: issue, verified: true)
                } else {
                    value = KnownIssue(issue: try JSONDecoder().decode(JiraIssue.self, from: data), verified: false)
                }
                // The canonical record wins equal revisions over legacy records.
                if let old = result[value.issue.id] {
                    result[value.issue.id] = value.accepting(old)
                } else { result[value.issue.id] = value }
            }
        }
        let metadata = try epics(result.values.compactMap { $0.issue.epicLink?.key }, in: db, site: site, account: account)
        for (id, value) in result {
            if let link = value.issue.epicLink, let saved = metadata[link.key] {
                var issue = value.issue
                issue.epicLink = saved.epic.restoringPresentation(from: link)
                result[id] = KnownIssue(issue: issue, verified: value.verified)
            }
        }
        return result
    }

    static func presenting(_ detail: CachedIssueDetail, in db: Database, site: String, account: String) throws -> CachedIssueDetail {
        let known = try knownIssues([detail.issue.id], in: db, site: site, account: account)
        return known[detail.issue.id].map { detail.reconciling($0.issue) } ?? detail
    }
}
