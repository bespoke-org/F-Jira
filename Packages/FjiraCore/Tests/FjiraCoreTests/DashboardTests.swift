import Foundation
import XCTest
@testable import FjiraCore

@MainActor
final class DashboardTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com")

    func testPersonalQueriesIncludeImplementerAndStayInsideProject() throws {
        let config = try DashboardConfiguration.decode(Data(#"[{"id":"customfield_12345","name":" Implementer "},{"id":"customfield_7","name":"Reporter"},{"id":"bad","name":"Implementer"}]"#.utf8))
        XCTAssertEqual(config.implementerFields, ["customfield_12345"])
        XCTAssertTrue(try DashboardSection.myIssues.query(projectID: "10000", configuration: config).jql.contains(#"status NOT IN ("New", "Backlog")"#))
        XCTAssertTrue(try DashboardSection.upNext.query(projectID: "10000", configuration: config).jql.contains(#"(statusCategory = "To Do" OR status IN ("New", "Backlog"))"#))
        for section in DashboardSection.allCases {
            let jql = try section.query(projectID: "10000", configuration: config).jql
            XCTAssertTrue(jql.hasPrefix("project = 10000 AND ((assignee = currentUser() OR cf[12345] = currentUser()) AND "), jql)
        }
        XCTAssertTrue(try DashboardSection.upNext.query(projectID: "10000", configuration: config).jql.contains("statusCategory = \"To Do\""))
        XCTAssertTrue(try DashboardSection.recentlyDone.query(projectID: "10000", configuration: config).jql.contains("resolved >= -14d"))
        XCTAssertEqual(try DashboardConfiguration.decode(Data("[]".utf8)).ownershipJQL, "(assignee = currentUser())")
    }

    func testCommentScopesAndTruncatedCommentsUseNewestPage() async throws {
        let transport = DashboardTransport(tail: true)
        let client = JiraClient(transport: transport)
        let config = try DashboardConfiguration.decode(Data(dashboardFields.utf8))
        for scope in DashboardCommentScope.allCases {
            let page = try await client.dashboardCommentPage(site: site, token: "fixture", projectID: "10000", scope: scope, configuration: config, startAt: 0)
            XCTAssertEqual(page.comments.map(\.comment.id), ["newest"])
            XCTAssertEqual(page.extraPages.count, 1)
        }
        let requests = await transport.requests
        let searches = try requests.filter { $0.url?.lastPathComponent == "search" }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any])["jql"] as? String
        }
        XCTAssertTrue(try XCTUnwrap(searches[0]).contains("(assignee = currentUser() OR cf[12345] = currentUser())"))
        XCTAssertFalse(try XCTUnwrap(searches[1]).contains("currentUser"))
        XCTAssertTrue(searches.allSatisfy { $0?.hasPrefix("project = 10000 AND (") == true })
        XCTAssertTrue(requests.filter { $0.url?.lastPathComponent == "comment" }.allSatisfy { $0.url?.query?.contains("startAt=50") == true })
    }

    func testCommentTailRespectsSmallerServerPageLimit() async throws {
        let transport = DashboardTransport(tail: true, smallCommentPages: true)
        let page = try await JiraClient(transport: transport).dashboardCommentPage(site: site, token: "fixture", projectID: "10000",
            scope: .mine, configuration: DashboardConfiguration.decode(Data(dashboardFields.utf8)), startAt: 0)
        XCTAssertEqual(page.comments.count, 50)
        XCTAssertEqual(page.comments.last?.comment.id, "99")
        XCTAssertEqual(page.extraPages["1"]?.map(\.page.startAt), [50, 70, 90])
        let cache = try ConnectionCache(path: ":memory:")
        let snapshot = CachedDashboardComments(scope: .mine, pages: [page], since: .distantPast)
        try await cache.saveDashboardComments(snapshot, project: "10000", site: site.identifier, account: "alice")
        let restored = try await cache.loadDashboardComments(scope: .mine, project: "10000", site: site.identifier, account: "alice")
        let otherScope = try await cache.loadDashboardComments(scope: .project, project: "10000", site: site.identifier, account: "alice")
        let otherAccount = try await cache.loadDashboardComments(scope: .mine, project: "10000", site: site.identifier, account: "bob")
        XCTAssertEqual(restored?.comments.count, 50)
        XCTAssertEqual(restored?.pages.first?.extraPages["1"]?.last?.response, page.extraPages["1"]?.last?.response)
        XCTAssertNil(otherScope)
        XCTAssertNil(otherAccount)
    }

    func testCommentsSortByCreationFilterOldEntriesAndDeduplicate() throws {
        let page = try dashboardPage()
        let entries = try [
            ("old", "2026-09-01T10:00:00.000+0300"),
            ("earlier", "2026-10-14T10:00:00.000+0300"),
            ("latest", "2026-10-15T11:00:00.000+0300")
        ].map { id, created in
            DashboardComment(issue: page.page.issues[0], comment: try dashboardComment(id, created: created))
        }
        let chunk = DashboardCommentPage(issues: page, comments: entries, extraPages: [:])
        let snapshot = CachedDashboardComments(scope: .mine, pages: [chunk, chunk], since: try XCTUnwrap(DashboardDate.parse("2026-10-08T00:00:00Z")))
        XCTAssertEqual(snapshot.comments.map(\.comment.id), ["latest", "earlier"])
        XCTAssertFalse(snapshot.needsMoreIssues)
        XCTAssertEqual(snapshot.comments[0].preview, "A new comment")
    }

    func testScanContinuesUntilOlderIssuesCannotContainNewerComments() throws {
        let page = try dashboardPage(total: 100, updated: "2026-10-14T10:00:00Z")
        let comments = try (0..<20).map {
            DashboardComment(issue: page.page.issues[0], comment: try dashboardComment(String($0), created: "2026-10-15T11:00:00Z"))
        }
        let since = try XCTUnwrap(DashboardDate.parse("2026-10-08T00:00:00Z"))
        XCTAssertFalse(CachedDashboardComments(scope: .project, pages: [.init(issues: page, comments: comments, extraPages: [:])], since: since).needsMoreIssues)
        XCTAssertTrue(CachedDashboardComments(scope: .project, pages: [.init(issues: page, comments: Array(comments.prefix(10)), extraPages: [:])], since: since).needsMoreIssues)
        let unknownDate = try dashboardPage(total: 100, updated: "invalid")
        XCTAssertTrue(CachedDashboardComments(scope: .project, pages: [.init(issues: unknownDate, comments: comments, extraPages: [:])], since: since).needsMoreIssues)
    }

    func testSnapshotsAndVisitsSurviveRestartWithoutPollutingSearchHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let config = try DashboardConfiguration.decode(Data(dashboardFields.utf8))
        let query = try DashboardSection.myIssues.query(projectID: "10000", configuration: config)
        let page = try dashboardPage()
        try await cache.saveDashboardConfiguration(config, site: site.identifier, account: "alice")
        try await cache.saveDashboardSection(.init(query: query, generation: UUID(), pages: [page]), section: .myIssues, site: site.identifier, account: "alice")
        for number in 1...22 {
            let issue = try dashboardPage(id: number).page.issues[0]
            try await cache.recordIssueVisit(issue, project: "10000", site: site.identifier, account: "alice", at: Date(timeIntervalSince1970: Double(number)))
        }
        let first = page.page.issues[0]
        try await cache.recordIssueVisit(first, project: "10000", site: site.identifier, account: "alice", at: Date(timeIntervalSince1970: 100))
        try await cache.recordIssueVisit(first, project: "10000", site: site.identifier, account: "alice", at: Date(timeIntervalSince1970: 99))
        let reopened = try ConnectionCache(path: path)
        let snapshot = try await reopened.loadDashboardSection(.myIssues, project: "10000", site: site.identifier, account: "alice")
        let visits = try await reopened.recentlyViewed(project: "10000", site: site.identifier, account: "alice")
        let history = try await reopened.recentSearches(site: site.identifier, account: "alice", project: "10000")
        let otherAccount = try await reopened.loadDashboardSection(.myIssues, project: "10000", site: site.identifier, account: "bob")
        let otherProject = try await reopened.recentlyViewed(project: "20000", site: site.identifier, account: "alice")
        XCTAssertEqual(snapshot?.pages.first?.response, page.response)
        XCTAssertEqual(visits.count, 20)
        XCTAssertEqual(visits.first?.issue.key, "EX-1")
        XCTAssertEqual(visits.first?.viewedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(otherAccount)
        XCTAssertTrue(otherProject.isEmpty)
    }

    func testCachedContentAppearsBeforeCredentialsAndSurvivesOfflineRefresh() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let config = try DashboardConfiguration.decode(Data(dashboardFields.utf8))
        let query = try DashboardSection.myIssues.query(projectID: "10000", configuration: config)
        try await cache.saveDashboardConfiguration(config, site: site.identifier, account: "alice")
        try await cache.saveDashboardSection(.init(query: query, generation: UUID(), pages: [dashboardPage()]), section: .myIssues, site: site.identifier, account: "alice")
        let reader = DashboardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: DashboardTransport(offline: true)), token: {
            Thread.sleep(forTimeInterval: 0.3)
            return "fixture"
        })
        defer { reader.reset() }
        reader.openProject("10000")
        await reader.currentTask?.value // Disk restoration schedules the refresh separately.
        XCTAssertEqual(reader.sections[.myIssues]?.issues.first?.key, "EX-1")
        XCTAssertTrue(reader.isLoading, "Cached content should be visible while credentials are pending")
        await reader.currentTask?.value
        await reader.commentTask?.value
        XCTAssertEqual(reader.sections[.myIssues]?.issues.first?.key, "EX-1")
        XCTAssertNotNil(reader.sectionErrors[.myIssues])
    }

    func testCurrentIssuesFiltersDownloadedNewAndBacklogTasksBeforeRefresh() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let config = try DashboardConfiguration.decode(Data(dashboardFields.utf8))
        let oldQuery = try ProjectQuery(projectID: "10000", input: "jql: \(config.ownershipJQL) AND statusCategory != Done ORDER BY priority DESC, updated DESC")
        let data = Data(#"{"startAt":0,"maxResults":50,"total":3,"issues":[{"id":"1","key":"EX-1","fields":{"summary":"Not started","status":{"name":"New"}}},{"id":"3","key":"EX-3","fields":{"summary":"Queued","status":{"name":"Backlog"}}},{"id":"2","key":"EX-2","fields":{"summary":"In review","status":{"name":"Reviewing"}}}]}"#.utf8)
        let page = CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: data), response: data, fetchedAt: Date())
        try await cache.saveDashboardConfiguration(config, site: site.identifier, account: "alice")
        try await cache.saveDashboardSection(.init(query: oldQuery, generation: UUID(), pages: [page]), section: .myIssues, site: site.identifier, account: "alice")
        let reader = DashboardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: DashboardTransport(offline: true)), token: { "fixture" })
        defer { reader.reset() }
        reader.openProject("10000")
        await reader.currentTask?.value
        let shown = try XCTUnwrap(reader.snapshot(for: .myIssues))
        XCTAssertEqual(shown.issues.map(\.key), ["EX-2"])
        XCTAssertEqual(shown.total, 1)
        XCTAssertTrue(shown.query.jql.contains(#"status NOT IN ("New", "Backlog")"#), "View all must use the updated filter too")
        XCTAssertEqual(shown.pages.first?.response, data, "Keep the complete downloaded response")
        await reader.currentTask?.value
        XCTAssertEqual(reader.snapshot(for: .myIssues)?.issues.map(\.key), ["EX-2"])
    }

    func testResizingExtendsCompletionHistoryAndKeepsItWhenShrinking() async throws {
        let transport = DashboardTransport()
        let reader = DashboardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"), client: JiraClient(transport: transport), token: { "fixture" })
        defer { reader.reset() }
        reader.openProject("10000")
        await reader.currentTask?.value
        await reader.currentTask?.value
        XCTAssertEqual(reader.completion?.weeks.count, 10)
        reader.ensureCompletionWeeks(20)
        reader.ensureCompletionWeeks(26)
        await reader.completionHistoryTask?.value
        XCTAssertEqual(reader.completion?.weeks.count, 26)
        reader.ensureCompletionWeeks(8)
        XCTAssertEqual(reader.completion?.weeks.count, 26, "Shrinking must keep downloaded history")
        let requests = await transport.requests
        let countRequests = requests.filter {
            guard let data = $0.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return body["maxResults"] as? Int == 0
        }
        XCTAssertEqual(countRequests.count, 26, "Resizing must not refetch the existing ten weeks")
        reader.ensureCompletionWeeks(30)
        reader.openProject("20000")
        await reader.currentTask?.value
        await reader.currentTask?.value
        XCTAssertEqual(reader.completion?.weeks.count, 30)
        XCTAssertTrue(reader.completion?.weeks.allSatisfy { $0.period.query.projectID == "20000" } == true)
    }

    func testProjectSwitchDiscardsLateResultsAndCommentRefreshIsBounded() async throws {
        let transport = DashboardTransport(total: 500, delay: true)
        let reader = DashboardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"), client: JiraClient(transport: transport), token: { "fixture" })
        defer { reader.reset() }
        reader.openProject("10000")
        await reader.currentTask?.value
        reader.openProject("20000")
        await reader.currentTask?.value
        await reader.currentTask?.value
        await reader.commentTask?.value
        XCTAssertEqual(reader.projectID, "20000")
        XCTAssertTrue(reader.sections.values.allSatisfy { $0.query.projectID == "20000" })
        XCTAssertEqual(reader.sections.count, 3)
        XCTAssertEqual(reader.completion?.weeks.count, 10)
        XCTAssertTrue(reader.completion?.weeks.allSatisfy { $0.period.query.projectID == "20000" } == true)
        XCTAssertEqual(reader.comments?.pages.count, 3)
        XCTAssertTrue(reader.comments?.needsMoreIssues == true)
        reader.selectCommentScope(.project)
        await reader.commentTask?.value
        XCTAssertEqual(reader.comments?.scope, .project)
        XCTAssertEqual(reader.comments?.pages.count, 3)
    }
}

private let dashboardFields = #"[{"id":"customfield_12345","name":"Implementer"}]"#

private func dashboardComment(_ id: String, created: String) throws -> JiraComment {
    try JSONDecoder().decode(JiraComment.self, from: JSONSerialization.data(withJSONObject: [
        "id": id, "created": created, "body": " A new\n comment ", "author": ["displayName": "Alice"]
    ]))
}

private func dashboardPage(id: Int = 1, total: Int = 1, start: Int = 0, updated: String = "2026-10-15T12:00:00Z", truncated: Bool = false) throws -> CachedIssuePage {
    let comments: [String: Any] = truncated
        ? ["startAt": 0, "maxResults": 1, "total": 100, "comments": [["id": "oldest", "created": "2026-01-01T00:00:00Z"]]]
        : ["startAt": 0, "maxResults": 50, "total": 0, "comments": []]
    let data = try JSONSerialization.data(withJSONObject: [
        "startAt": start, "maxResults": 50, "total": total,
        "issues": [["id": String(id), "key": "EX-\(id)", "fields": ["summary": "Example \(id)", "updated": updated, "comment": comments]]]
    ])
    return CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: data), response: data, fetchedAt: Date())
}

private actor DashboardTransport: JiraTransport {
    let offline: Bool
    let tail: Bool
    let total: Int
    let delay: Bool
    let smallCommentPages: Bool
    var requests: [URLRequest] = []
    init(offline: Bool = false, tail: Bool = false, total: Int = 1, delay: Bool = false, smallCommentPages: Bool = false) {
        self.offline = offline; self.tail = tail; self.total = total; self.delay = delay; self.smallCommentPages = smallCommentPages
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        if delay { try? await Task.sleep(for: .milliseconds(30)) }
        let data: Data
        switch request.url?.lastPathComponent {
        case "field": data = Data(dashboardFields.utf8)
        case "myself": data = Data(#"{"timeZone":"Europe/Saratov"}"#.utf8)
        case "comment":
            if smallCommentPages {
                let start = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "startAt" }!.value!)!
                let comments = (start..<min(100, start + 20)).map { ["id": String($0), "created": "2026-10-15T10:00:00Z"] }
                data = try JSONSerialization.data(withJSONObject: ["startAt": start, "maxResults": 20, "total": 100, "comments": comments])
            } else {
                data = Data(#"{"startAt":50,"maxResults":50,"total":51,"comments":[{"id":"newest","created":"2026-10-15T10:00:00.000+0300"}]}"#.utf8)
            }
        default:
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any]
            let start = body?["startAt"] as? Int ?? 0
            data = try dashboardPage(id: start + 1, total: total, start: start, truncated: tail).response
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
