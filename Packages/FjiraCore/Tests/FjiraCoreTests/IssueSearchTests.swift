import Foundation
import GRDB
import XCTest
@testable import FjiraCore

final class IssueSearchTests: XCTestCase {
    func testScopesBooleanExpressionsAndKeepsOrderingOutsideFilter() throws {
        let query = try ProjectQuery(projectID: "10000", input: "status = Open OR assignee = currentUser() order by priority DESC")
        XCTAssertEqual(query.jql, "project = 10000 AND (status = Open OR assignee = currentUser()) order by priority DESC")
        XCTAssertEqual(try ProjectQuery(projectID: "10000", input: "").jql, "project = 10000 ORDER BY updated DESC, key ASC")
        XCTAssertEqual(try ProjectQuery(projectID: "10000", input: "ORDER BY key ASC").jql, "project = 10000 ORDER BY key ASC")
    }

    func testIgnoresOrderKeywordsInsideQuotedStringsAndNestedFunctions() throws {
        let query = try ProjectQuery(projectID: "10000", input: #"summary ~ "order by" AND status in ("Open", "In Progress") ORDER BY updated DESC"#)
        XCTAssertEqual(query.jql, #"project = 10000 AND (summary ~ "order by" AND status in ("Open", "In Progress")) ORDER BY updated DESC"#)
        let nested = try ProjectQuery(projectID: "10000", input: #"issue in linkedIssues("EX-1", "order by")"#)
        XCTAssertTrue(nested.jql.hasSuffix("ORDER BY updated DESC, key ASC"))
    }

    func testRejectsScopeEscapesAndMalformedQueryStructure() {
        for input in ["status = Open) OR project = 20000 OR (status = Closed", #"summary ~ "unclosed"#, "status in (Open", "ORDER BY", "ORDER BY key ORDER BY updated"] {
            XCTAssertThrowsError(try ProjectQuery(projectID: "10000", input: input), input)
        }
        XCTAssertThrowsError(try ProjectQuery(projectID: "10000 OR project = 20000", input: ""))
    }

    func testLoadsProjectsAndRetainsUnmodeledFields() async throws {
        let transport = StubTransport([(200, #"[{"id":"10000","key":"EX","name":"Example","avatarUrls":{"16x16":"https://jira.example.com/avatar/small.png","48x48":"https://jira.example.com/avatar/project.png"},"extra":"keep"},{"id":"20000","key":"OLD","name":"Older cached project"}]"#)])
        let result = try await JiraClient(transport: transport).projects(site: JiraSite("https://jira.example.com/jira"), token: "token")
        XCTAssertEqual(result.projects.first?.key, "EX")
        XCTAssertEqual(result.projects.first?.avatarURL?.absoluteString, "https://jira.example.com/avatar/project.png")
        XCTAssertNil(result.projects.last?.avatarURL)
        XCTAssertTrue(String(decoding: result.response, as: UTF8.self).contains("keep"))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.first?.url?.path, "/jira/rest/api/2/project")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testSearchUsesReadOnlyPOSTAndHandlesServerPageLimitAndNullableFields() async throws {
        let transport = StubTransport([(200, pageJSON(start: 0, total: 3, keys: ["EX-1", "EX-2"]))])
        let query = try ProjectQuery(projectID: "10000", input: "assignee = currentUser()")
        let result = try await JiraClient(transport: transport).search(site: JiraSite("https://jira.example.com/jira"), token: "token", query: query)
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/jira/rest/api/2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body["jql"] as? String, query.jql)
        XCTAssertEqual(body["startAt"] as? Int, 0)
        XCTAssertEqual(body["maxResults"] as? Int, 50)
        XCTAssertEqual(result.page.maxResults, 2)
        XCTAssertEqual(result.page.issues.first?.assignee, "Unassigned")
        XCTAssertEqual(result.page.issues.first?.priority, "—")
        XCTAssertGreaterThan(try XCTUnwrap(result.page.issues.first?.updated), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testDisplaysJiraQueryValidationErrors() async throws {
        let transport = StubTransport([(400, #"{"errorMessages":["Field 'foo' does not exist."],"errors":{}}"#)])
        do {
            _ = try await JiraClient(transport: transport).search(
                site: JiraSite("https://jira.example.com"), token: "token",
                query: ProjectQuery(projectID: "10000", input: "foo = bar")
            )
            XCTFail("Expected query validation failure")
        } catch { XCTAssertEqual(error as? JiraError, .queryRejected("Field 'foo' does not exist.")) }
    }

    func testRejectsUnexpectedOffsetsAndEmptyIncompletePages() async throws {
        for json in [pageJSON(start: 50, total: 100, keys: ["EX-1"]), pageJSON(start: 0, total: 100, keys: [])] {
            do {
                _ = try await JiraClient(transport: StubTransport([(200, json)])).search(
                    site: JiraSite("https://jira.example.com"), token: "token",
                    query: ProjectQuery(projectID: "10000", input: "")
                )
                XCTFail("Expected inconsistent pagination")
            } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
        }
    }

    func testSearchCacheRestoresOrderPagesSelectionAndAccountIsolation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let query = try ProjectQuery(projectID: "10000", input: "ORDER BY key DESC")
        try await cache.savePage(page(start: 0, total: 3, keys: ["EX-3", "EX-2"]), site: "site", account: "alice", query: query)
        let firstValue = try await cache.loadSearch(site: "site", account: "alice", query: query)
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.nextStartAt, 2)
        XCTAssertTrue(first.hasMore)
        try await cache.savePage(page(start: 2, total: 3, keys: ["EX-1"]), site: "site", account: "alice", query: query, expectedGeneration: first.generation)
        try await cache.saveSelection(site: "site", account: "alice", project: query.projectID, input: query.input)
        let reopened = try ConnectionCache(path: path)
        let restoredValue = try await reopened.loadSearch(site: "site", account: "alice", query: query)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.issues.map(\.key), ["EX-3", "EX-2", "EX-1"])
        XCTAssertEqual(restored.pages.count, 2)
        XCTAssertFalse(restored.hasMore)
        XCTAssertEqual(restored.pages.first?.response, first.pages.first?.response)
        let selection = try await reopened.loadSelection(site: "site", account: "alice")
        XCTAssertEqual(selection?.project, query.projectID)
        XCTAssertEqual(selection?.input, query.input)
        let otherAccount = try await reopened.loadSearch(site: "site", account: "bob", query: query)
        let otherSite = try await reopened.loadSearch(site: "other", account: "alice", query: query)
        let otherProject = try await reopened.loadSearch(site: "site", account: "alice", query: ProjectQuery(projectID: "20000", input: query.input))
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherSite)
        XCTAssertNil(otherProject)
    }

    func testRefreshingSearchReplacesMembershipButRetainsDownloadedIssueData() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let query = try ProjectQuery(projectID: "10000", input: "")
        try await cache.savePage(page(start: 0, total: 3, keys: ["EX-1", "EX-2"]), site: "site", account: "alice", query: query)
        let firstValue = try await cache.loadSearch(site: "site", account: "alice", query: query)
        let first = try XCTUnwrap(firstValue)
        try await cache.savePage(page(start: 2, total: 3, keys: ["EX-3"]), site: "site", account: "alice", query: query, expectedGeneration: first.generation)
        try await cache.savePage(page(start: 0, total: 1, keys: ["EX-2"]), site: "site", account: "alice", query: query)
        let refreshedValue = try await cache.loadSearch(site: "site", account: "alice", query: query)
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertEqual(refreshed.issues.map(\.key), ["EX-2"])
        XCTAssertEqual(refreshed.pages.count, 1)
        let removedIssue = try await cache.cachedIssueResponse(site: "site", account: "alice", issueID: "EX-3")
        XCTAssertNotNil(removedIssue)
        do {
            try await cache.savePage(page(start: 2, total: 3, keys: ["EX-4"]), site: "site", account: "alice", query: query, expectedGeneration: first.generation)
            XCTFail("Expected rejection of an obsolete pagination request")
        } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
        let preserved = try await cache.loadSearch(site: "site", account: "alice", query: query)
        XCTAssertEqual(preserved?.issues.map(\.key), ["EX-2"])
    }

    func testProjectsSurviveReopeningAndFailedSearchPreservesCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let client = JiraClient(transport: StubTransport([
            (200, #"[{"id":"10000","key":"EX","name":"Example","avatarUrls":{"48x48":"https://jira.example.com/avatar/project.png"}}]"#),
            (200, pageJSON(start: 0, total: 1, keys: ["EX-1"])),
            (503, "unavailable")
        ]))
        let site = try JiraSite("https://jira.example.com")
        let projects = try await client.projects(site: site, token: "token")
        try await cache.saveProjects(projects, site: site.identifier, account: "alice")
        let query = try ProjectQuery(projectID: "10000", input: "")
        let result = try await client.search(site: site, token: "token", query: query)
        try await cache.savePage(result, site: site.identifier, account: "alice", query: query)
        do {
            let failed = try await client.search(site: site, token: "token", query: query)
            try await cache.savePage(failed, site: site.identifier, account: "alice", query: query)
            XCTFail("Expected server failure")
        } catch { XCTAssertEqual(error as? JiraError, .httpStatus(503)) }
        let reopened = try ConnectionCache(path: path)
        let restoredProjects = try await reopened.loadProjects(site: site.identifier, account: "alice")
        let restoredSearch = try await reopened.loadSearch(site: site.identifier, account: "alice", query: query)
        XCTAssertEqual(restoredProjects?.response, projects.response)
        XCTAssertEqual(restoredProjects?.projects.first?.avatarURL, projects.projects.first?.avatarURL)
        XCTAssertEqual(restoredSearch?.issues.map(\.key), ["EX-1"])
    }

    func testBrowsingMigrationPreservesExistingConnection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let oldDatabase = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("connections") { db in
            try db.create(table: "connection") { t in
                t.column("site", .text).notNull()
                t.column("account", .text).notNull()
                t.column("snapshot", .blob).notNull()
                t.primaryKey(["site", "account"])
            }
        }
        try migrator.migrate(oldDatabase)
        let connection = try await JiraClient(transport: StubTransport([
            (200, #"{"name":"alice","displayName":"Alice"}"#), (200, #"{"version":"9.12"}"#)
        ])).verify(site: JiraSite("https://jira.example.com"), token: "token")
        try await oldDatabase.write { db in
            try db.execute(sql: "INSERT INTO connection VALUES (?, ?, ?)", arguments: [connection.site.identifier, "alice", try JSONEncoder().encode(connection)])
        }
        let migrated = try ConnectionCache(path: path)
        let restored = try await migrated.load(site: connection.site.identifier, account: "alice")
        XCTAssertEqual(restored?.user.displayName, "Alice")
        let projects = try await migrated.loadProjects(site: connection.site.identifier, account: "alice")
        XCTAssertNil(projects)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func page(start: Int, total: Int, keys: [String]) throws -> CachedIssuePage {
        let data = Data(pageJSON(start: start, total: total, keys: keys).utf8)
        return CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: data), response: data, fetchedAt: Date())
    }

    private func pageJSON(start: Int, total: Int, keys: [String]) -> String {
        let issues = keys.map { key in
            #"{"id":""# + key + #"","key":""# + key + #"","fields":{"summary":"Summary","status":{"name":"Open"},"assignee":null,"priority":null,"updated":"2026-10-13T12:00:00.000+0400"},"extra":"retained"}"#
        }.joined(separator: ",")
        return "{\"startAt\":\(start),\"maxResults\":2,\"total\":\(total),\"issues\":[\(issues)]}"
    }
}
