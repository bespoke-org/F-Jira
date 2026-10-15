import Foundation
import GRDB

extension ConnectionCache {
    public func saveDashboardConfiguration(_ value: DashboardConfiguration, site: String, account: String) throws {
        try database.write { db in try Self.writeDashboardValue(value, resource: "dashboard-fields", db: db, site: site, account: account) }
    }

    public func loadDashboardConfiguration(site: String, account: String) throws -> DashboardConfiguration? {
        try database.read { db in try Self.dashboardValue(resource: "dashboard-fields", db: db, site: site, account: account) }
    }

    public func saveDashboardSection(_ value: CachedSearch, section: DashboardSection, site: String, account: String) throws {
        try database.write { db in
            _ = try Self.mergeIssues(value.issues, in: db, site: site, account: account)
            try Self.writeDashboardValue(value, resource: "dashboard:\(value.query.projectID):\(section.rawValue)", db: db, site: site, account: account)
        }
    }

    public func loadDashboardSection(_ section: DashboardSection, project: String, site: String, account: String) throws -> CachedSearch? {
        try database.read { db in
            guard let saved: CachedSearch = try Self.dashboardValue(resource: "dashboard:\(project):\(section.rawValue)", db: db, site: site, account: account) else { return nil }
            let known = try Self.knownIssues(saved.issues.map(\.id), in: db, site: site, account: account)
            return saved.reconciling(known.values.map(\.issue))
        }
    }

    public func saveDashboardComments(_ value: CachedDashboardComments, project: String, site: String, account: String) throws {
        try database.write { db in
            _ = try Self.mergeIssues(value.pages.flatMap { $0.issues.page.issues }, in: db, site: site, account: account)
            try Self.writeDashboardValue(value, resource: "dashboard-comments:\(project):\(value.scope.rawValue)", db: db, site: site, account: account)
        }
    }

    public func loadDashboardComments(scope: DashboardCommentScope, project: String, site: String, account: String) throws -> CachedDashboardComments? {
        try database.read { db in try Self.dashboardValue(resource: "dashboard-comments:\(project):\(scope.rawValue)", db: db, site: site, account: account) }
    }

    public func saveDashboardCompletion(_ value: CachedDashboardCompletion, project: String, site: String, account: String) throws {
        try database.write { db in
            try Self.writeDashboardValue(value, resource: "dashboard-completion:\(project)", db: db, site: site, account: account)
        }
    }

    public func loadDashboardCompletion(project: String, site: String, account: String) throws -> CachedDashboardCompletion? {
        try database.read { db in
            try Self.dashboardValue(resource: "dashboard-completion:\(project)", db: db, site: site, account: account)
        }
    }

    public func recordIssueVisit(_ issue: JiraIssue, project: String, site: String, account: String, at date: Date = Date()) throws {
        try database.write { db in
            let resource = "viewed-issues:\(project)"
            var visits: [ViewedIssue] = try Self.dashboardValue(resource: resource, db: db, site: site, account: account) ?? []
            if let newer = visits.first(where: { $0.id == issue.key }), newer.viewedAt > date { return }
            visits.removeAll { $0.id == issue.key }
            visits.append(ViewedIssue(issue: issue, viewedAt: date))
            visits = Array(visits.sorted { $0.viewedAt > $1.viewedAt }.prefix(20))
            try Self.writeDashboardValue(visits, resource: resource, db: db, site: site, account: account)
        }
    }

    public func recentlyViewed(project: String, site: String, account: String) throws -> [ViewedIssue] {
        try database.read { db in
            let visits: [ViewedIssue] = try Self.dashboardValue(resource: "viewed-issues:\(project)", db: db, site: site, account: account) ?? []
            let known = try Self.knownIssues(visits.map { $0.issue.id }, in: db, site: site, account: account)
            return visits.map { visit in
                ViewedIssue(issue: known[visit.issue.id].map { visit.issue.accepting($0.issue) } ?? visit.issue, viewedAt: visit.viewedAt)
            }
        }
    }

    private static func dashboardValue<T: Decodable>(resource: String, db: Database, site: String, account: String) throws -> T? {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM response_cache WHERE site = ? AND account = ? AND resource = ?",
                                             arguments: [site, account, resource]) else { return nil }
        return try JSONDecoder().decode(T.self, from: payload)
    }

    private static func writeDashboardValue<T: Encodable>(_ value: T, resource: String, db: Database, site: String, account: String) throws {
        try db.execute(sql: """
            INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(site, account, resource) DO UPDATE SET payload = excluded.payload
            """, arguments: [site, account, resource, try JSONEncoder().encode(value)])
    }
}
