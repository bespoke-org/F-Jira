import Foundation
import XCTest
@testable import FjiraCore

@MainActor
final class DashboardCompletionTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com")
    private var configuration: DashboardConfiguration {
        get throws { try DashboardConfiguration.decode(Data(#"[{"id":"customfield_12345","name":"Implementer"}]"#.utf8)) }
    }

    func testWeeksFollowJiraTimezoneAndCrossYearWithoutGaps() throws {
        let periods = try CompletionWeek.periods(now: date("2026-01-04T22:00:00Z"), timeZone: XCTUnwrap(TimeZone(identifier: "Europe/Saratov")), projectID: "10000", configuration: configuration)
        XCTAssertEqual(periods.count, 10)
        XCTAssertEqual(periods.last?.start, try date("2026-01-04T20:00:00Z"), "It is already Monday in the Jira profile timezone")
        for (earlier, later) in zip(periods, periods.dropFirst()) { XCTAssertEqual(earlier.end, later.start) }
        let last = try XCTUnwrap(periods.last)
        XCTAssertTrue(last.query.jql.hasPrefix("project = 10000 AND ((assignee = currentUser() OR cf[12345] = currentUser()) AND statusCategory = Done"))
        XCTAssertTrue(last.query.jql.contains(#"resolved >= "2026-01-05" AND resolved < "2026-01-12""#))
        XCTAssertTrue(periods.first!.query.jql.contains(#"resolved >= "2025-11-03""#))
    }

    func testWeekBoundariesHandleDaylightSavingTime() throws {
        let periods = try CompletionWeek.periods(now: date("2026-03-09T12:00:00Z"), timeZone: XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")), projectID: "10000", configuration: configuration)
        let previous = periods[periods.count - 2]
        XCTAssertEqual(previous.end.timeIntervalSince(previous.start), 167 * 3600)
        XCTAssertTrue(previous.query.jql.contains(#"resolved >= "2026-03-02" AND resolved < "2026-03-09""#))
        XCTAssertEqual(previous.end, periods.last?.start)
    }

    func testCountsAreNotLimitedToDownloadedIssuePages() async throws {
        let transport = CompletionTransport()
        let snapshot = try await JiraClient(transport: transport).dashboardCompletion(site: site, token: "fixture", projectID: "10000", configuration: configuration, now: date("2026-10-15T12:00:00Z"))
        XCTAssertEqual(snapshot.weeks.count, 10)
        XCTAssertEqual(snapshot.previousWeeks.count, 9)
        XCTAssertEqual(snapshot.currentWeek?.count, 123)
        XCTAssertTrue(snapshot.isCurrentWeek(at: try date("2026-10-15T12:00:00Z")))
        XCTAssertFalse(snapshot.isCurrentWeek(at: try date("2026-10-19T00:00:00Z")), "An old offline count must not be labeled this week")
        let requests = await transport.requests
        let searches = requests.filter { $0.url?.lastPathComponent == "search" }
        XCTAssertEqual(searches.count, 10)
        for request in searches {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["maxResults"] as? Int, 0)
            XCTAssertEqual(body["fields"] as? [String], [])
        }
        let concurrent = await transport.maxConcurrent
        XCTAssertLessThanOrEqual(concurrent, 3)
    }

    func testWiderHistoryFetchesOnlyMissingWeeksAndKeepsCurrentWeek() async throws {
        let transport = CompletionTransport()
        let client = JiraClient(transport: transport)
        let now = try date("2026-10-15T12:00:00Z")
        let initial = try await client.dashboardCompletion(site: site, token: "fixture", projectID: "10000", configuration: configuration, now: now)
        let wider = try await client.dashboardCompletion(site: site, token: "fixture", projectID: "10000", configuration: configuration, now: now, weekCount: 24, reusing: initial)
        XCTAssertEqual(wider.weeks.count, 24)
        XCTAssertEqual(wider.currentWeek?.id, initial.currentWeek?.id)
        XCTAssertEqual(wider.weeks.suffix(10).map(\.response), initial.weeks.map(\.response))
        XCTAssertEqual(wider.fetchedAt, initial.fetchedAt, "Expanding history must not claim existing totals were refreshed")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "search" }.count, 24)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "myself" }.count, 1)
    }

    func testInvalidCountDoesNotBecomeZero() async throws {
        do {
            _ = try await JiraClient(transport: CompletionTransport(count: -1)).dashboardCompletion(site: site, token: "fixture", projectID: "10000", configuration: configuration)
            XCTFail("Invalid statistics must fail, not appear as zero completed issues")
        } catch { XCTAssertEqual(error as? JiraError, .invalidResponse) }
    }

    func testCacheRestoresBeforeCredentialsAndPreservesCountsOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let snapshot = try await JiraClient(transport: CompletionTransport()).dashboardCompletion(site: site, token: "fixture", projectID: "10000", configuration: configuration)
        try await cache.saveDashboardConfiguration(configuration, site: site.identifier, account: "alice")
        try await cache.saveDashboardCompletion(snapshot, project: "10000", site: site.identifier, account: "alice")
        let reopened = try ConnectionCache(path: path)
        let restored = try await reopened.loadDashboardCompletion(project: "10000", site: site.identifier, account: "alice")
        let otherAccount = try await reopened.loadDashboardCompletion(project: "10000", site: site.identifier, account: "bob")
        let otherProject = try await reopened.loadDashboardCompletion(project: "20000", site: site.identifier, account: "alice")
        XCTAssertEqual(restored?.currentWeek?.response, snapshot.currentWeek?.response)
        XCTAssertEqual(restored?.profileResponse, snapshot.profileResponse)
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherProject)
        let reader = DashboardReader(site: site, account: "alice", cache: reopened, client: JiraClient(transport: CompletionTransport(offline: true)), token: {
            Thread.sleep(forTimeInterval: 0.2)
            return "fixture"
        })
        defer { reader.reset() }
        reader.openProject("10000")
        await reader.currentTask?.value
        XCTAssertEqual(reader.completion?.currentWeek?.count, 123)
        XCTAssertTrue(reader.isLoading)
        await reader.currentTask?.value
        XCTAssertNotNil(reader.completionError)
        XCTAssertEqual(reader.completion?.currentWeek?.count, 123)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private actor CompletionTransport: JiraTransport {
    let count: Int
    let offline: Bool
    var requests: [URLRequest] = []
    var concurrent = 0
    var maxConcurrent = 0
    init(count: Int = 123, offline: Bool = false) { self.count = count; self.offline = offline }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        let json = request.url?.lastPathComponent == "myself" ? #"{"timeZone":"Europe/Saratov"}"# : "{\"total\":\(count)}"
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
