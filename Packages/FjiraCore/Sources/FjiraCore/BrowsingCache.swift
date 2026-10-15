import Foundation
import GRDB

extension ConnectionCache {
    public func saveProjects(_ projects: CachedProjects, site: String, account: String) throws {
        let data = try JSONEncoder().encode(projects)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO project_snapshot (site, account, snapshot) VALUES (?, ?, ?)
                ON CONFLICT(site, account) DO UPDATE SET snapshot = excluded.snapshot
                """, arguments: [site, account, data])
        }
    }

    public func loadProjects(site: String, account: String) throws -> CachedProjects? {
        try database.read { db in
            guard let data = try Data.fetchOne(db,
                sql: "SELECT snapshot FROM project_snapshot WHERE site = ? AND account = ?",
                arguments: [site, account]) else { return nil }
            return try JSONDecoder().decode(CachedProjects.self, from: data)
        }
    }

    public func loadSearch(site: String, account: String, query: ProjectQuery) throws -> CachedSearch? {
        try database.read { db in
            try Self.search(in: db, site: site, account: account, query: query)
        }
    }

    public func loadSearchPresentation(site: String, account: String, query: ProjectQuery) throws
        -> (search: CachedSearch, images: [String: CachedAvatar])? {
        try database.read { db in
            guard let search = try Self.search(in: db, site: site, account: account, query: query) else { return nil }
            return (search, try Self.cachedImages(in: db, site: site, account: account, urls: search.tableImageURLs))
        }
    }

    public func recentSearches(site: String, account: String, project: String) throws -> [CachedSearch] {
        try database.read { db in
            try Data.fetchAll(db,
                sql: "SELECT snapshot FROM search_snapshot WHERE site = ? AND account = ? AND project = ?",
                arguments: [site, account, project])
                .map { data in
                    let saved = try JSONDecoder().decode(CachedSearch.self, from: data).restoringMetadata
                    let known = try Self.knownIssues(saved.issues.map(\.id), in: db, site: site, account: account)
                    return saved.reconciling(known.values.map(\.issue))
                }
                .sorted { $0.fetchedAt > $1.fetchedAt }
        }
    }

    public func savePage(
        _ page: CachedIssuePage, site: String, account: String, query: ProjectQuery,
        expectedGeneration: UUID? = nil
    ) throws {
        try database.write { db in
            _ = try Self.mergeIssues(page.page.issues, in: db, site: site, account: account)
            var snapshot: CachedSearch
            if page.page.startAt == 0 {
                snapshot = CachedSearch(query: query, generation: UUID(), pages: [page])
            } else {
                guard var existing = try Self.search(in: db, site: site, account: account, query: query),
                      existing.generation == expectedGeneration,
                      existing.nextStartAt == page.page.startAt else {
                    throw SearchError.inconsistentPagination
                }
                existing.pages.append(page)
                snapshot = existing
            }
            try db.execute(sql: """
                INSERT INTO search_snapshot (site, account, project, input, snapshot) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(site, account, project, input) DO UPDATE SET snapshot = excluded.snapshot
                """, arguments: [site, account, query.projectID, query.input, try JSONEncoder().encode(snapshot)])
            // Retain previously fetched responses even when a refreshed search drops their pages.
            try db.execute(sql: """
                INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                """, arguments: [site, account, "search:\(query.projectID):\(query.input):\(page.page.startAt)", page.response])
            if let object = try JSONSerialization.jsonObject(with: page.response) as? [String: Any],
               let issues = object["issues"] as? [[String: Any]] {
                for issue in issues {
                    guard let id = issue["id"] as? String else { continue }
                    try db.execute(sql: """
                        INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
                        ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
                        """, arguments: [site, account, "issue-list:\(id)", try JSONSerialization.data(withJSONObject: issue)])
                }
            }
        }
    }

    public func cachedIssueResponse(site: String, account: String, issueID: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db,
                sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
                arguments: [site, account, "issue-list:\(issueID)"])
        }
    }

    public func saveSelection(site: String, account: String, project: String, input: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO browsing_selection (site, account, project, input) VALUES (?, ?, ?, ?)
                ON CONFLICT(site, account) DO UPDATE SET project = excluded.project, input = excluded.input
                """, arguments: [site, account, project, input])
        }
    }

    public func loadSelection(site: String, account: String) throws -> (project: String, input: String)? {
        try database.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT project, input FROM browsing_selection WHERE site = ? AND account = ?",
                arguments: [site, account]) else { return nil }
            return (row["project"], row["input"])
        }
    }

    private static func search(in db: Database, site: String, account: String, query: ProjectQuery) throws -> CachedSearch? {
        guard let data = try Data.fetchOne(db,
            sql: "SELECT snapshot FROM search_snapshot WHERE site = ? AND account = ? AND project = ? AND input = ?",
            arguments: [site, account, query.projectID, query.input]) else { return nil }
        let saved = try JSONDecoder().decode(CachedSearch.self, from: data).restoringMetadata
        let known = try knownIssues(saved.issues.map(\.id), in: db, site: site, account: account)
        return saved.reconciling(known.values.map(\.issue))
    }
}
