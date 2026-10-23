import Foundation
import XCTest
@testable import FjiraCore

final class BoardContentsTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com/jira")

    func testPositiveMembershipPreservesNullFieldsFirstMatchRankAndDefaultAcrossPages() async throws {
        let transport = ContentsTransport()
        let result = try await contents(transport)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.lanes().map { $0.columns.flatMap(\.issues).map(\.id) }, [["A"], ["B"], ["C"]])
        XCTAssertNil(result.issues.first { $0.id == "B" }?.fields.assignee)
        XCTAssertEqual(result.issues.first { $0.id == "B" }?.summary, "Full card B")
        let requests = await transport.requests.filter { $0.url?.lastPathComponent == "issue" }
        XCTAssertEqual(requests.count, 6, "All server-limited pages must be consumed before subtracting sets")
        for request in requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let jql = query.first { $0.name == "jql" }!.value!
            XCTAssertFalse(jql.contains("NOT"))
            let membership = jql.contains("labels =")
            XCTAssertEqual(query.first { $0.name == "fields" }!.value!.contains("summary"), !membership)
            XCTAssertEqual(query.first { $0.name == "maxResults" }?.value, "100")
        }
    }

    func testUnknownTotalsStillReadEveryFullPage() async throws {
        let result = try await contents(ContentsTransport(unknownTotals: true))
        XCTAssertEqual(Set(result.issues.map(\.id)), ["A", "B", "C"])
        XCTAssertTrue(result.isComplete)
    }

    func testRepeatedMembershipPageFailsInsteadOfPublishingIncompleteAssignment() async throws {
        do {
            _ = try await contents(ContentsTransport(repeatPage: true))
            XCTFail("Overlapping pages must not be accepted")
        } catch SearchError.inconsistentPagination { }
    }

    func testProjectedSettingsFallBackWhenRequiredKeysAreMissing() async throws {
        let transport = ContentsTransport(missingProjectedSettings: true)
        let settings = try await JiraClient(transport: transport).boardSwimlanes(site: site, token: "token", boardID: 1)
        XCTAssertEqual(settings.lanes.count, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("expand=workingDaysConfig"))
        XCTAssertFalse(requests[1].url!.absoluteString.contains("expand="))
    }

    @MainActor
    func testConditionalPollSkipsCardsUntilTokenChangesAndRetriesFailedChange() async throws {
        let transport = ContentsTransport(changeChecks: true)
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("1")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(20)) }
        defer { automatic.cancel() }
        try await waitForChecks(3, transport: transport)
        var requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "issue" }.count, 6)
        await transport.setFailLane(true)
        await transport.renameCardB()
        try await eventually { reader.errorMessage != nil && !reader.isLoading }
        XCTAssertEqual(reader.snapshot?.issues.first { $0.id == "B" }?.summary, "Full card B")
        await transport.setFailLane(false)
        try await eventually { reader.snapshot?.issues.first { $0.id == "B" }?.summary == "Renamed B" }
        automatic.cancel()
        await automatic.value
        XCTAssertNil(reader.errorMessage)
        requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "configuration" }.count, 1)
        let probes = requests.filter { $0.url?.lastPathComponent == "allData.json" }
        XCTAssertTrue(probes.dropFirst().allSatisfy { $0.url!.absoluteString.contains("etag=v1") },
                      "A changed token must not be accepted until every card query succeeds")
    }

    @MainActor
    func testUnchangedTokenStillForcesPeriodicConfigurationAndMembershipRefresh() async throws {
        let transport = ContentsTransport(changeChecks: true)
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("1")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        // Simulate a membership change which the private token does not describe.
        await transport.removeCardB()
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(15), fullRefreshEvery: .milliseconds(100)) }
        defer { automatic.cancel() }
        try await eventually { reader.snapshot?.issues.contains { $0.id == "B" } == false }
        automatic.cancel()
        await automatic.value
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "configuration" }.count, 2)
    }

    @MainActor
    private func waitForChecks(_ count: Int, transport: ContentsTransport) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await transport.requests.filter({ $0.url?.lastPathComponent == "allData.json" }).count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for conditional board checks")
    }

    @MainActor
    func testUnchangedAutomaticPollDoesNotRepublishButChangedFieldsDo() async throws {
        let transport = ContentsTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("1")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        var presentations = 0
        reader.onPresentation = { _ in presentations += 1 }
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(20)) }
        defer { automatic.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while await transport.requests.count < 21, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(presentations, 0)
        await transport.renameCardB()
        try await eventually { reader.snapshot?.issues.first { $0.id == "B" }?.summary == "Renamed B" }
        automatic.cancel()
        await automatic.value
        XCTAssertEqual(presentations, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "configuration" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "editmodel.json" }.count, 1)
        reader.refresh()
        try await eventually { !reader.isLoading }
        let afterManual = await transport.requests
        XCTAssertEqual(afterManual.filter { $0.url?.lastPathComponent == "configuration" }.count, 2)
    }

    @MainActor
    func testFailedLaneRefreshKeepsCompleteSnapshotThenRemovesDeletedCardsOnRecovery() async throws {
        let transport = ContentsTransport()
        let cache = try ConnectionCache(path: ":memory:")
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("1")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        let previous = reader.snapshot?.fetchedAt
        await transport.setFailLane(true)
        reader.refresh()
        try await eventually { !reader.isLoading }
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertEqual(reader.snapshot?.fetchedAt, previous)
        XCTAssertEqual(Set(reader.snapshot!.issues.map(\.id)), ["A", "B", "C"])
        await transport.setFailLane(false)
        await transport.removeCardB()
        reader.refresh()
        try await eventually { !reader.isLoading }
        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(Set(reader.snapshot!.issues.map(\.id)), ["A", "C"])
        let restored = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(Set(restored!.board.issues.map(\.id)), ["A", "C"])
    }

    private func contents(_ transport: ContentsTransport) async throws -> CachedBoard {
        let client = JiraClient(transport: transport)
        let (config, data) = try await client.boardConfiguration(site: site, token: "token", boardID: 1)
        let settings = try await client.boardSwimlanes(site: site, token: "token", boardID: 1)
        return try await client.boardContents(site: site, token: "token", board: JiraBoard(id: 1, name: "Board", type: "kanban"),
            configuration: config, configurationResponse: data, settings: settings)
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
}

private actor ContentsTransport: JiraTransport {
    let unknownTotals: Bool
    let repeatPage: Bool
    let missingProjectedSettings: Bool
    let changeChecks: Bool
    private var failLane = false
    private var removedB = false
    private var renamedB = false
    private(set) var requests: [URLRequest] = []

    init(unknownTotals: Bool = false, repeatPage: Bool = false, missingProjectedSettings: Bool = false, changeChecks: Bool = false) {
        self.unknownTotals = unknownTotals
        self.repeatPage = repeatPage
        self.missingProjectedSettings = missingProjectedSettings
        self.changeChecks = changeChecks
    }
    func setFailLane(_ value: Bool) { failLane = value }
    func removeCardB() { removedB = true }
    func renameCardB() { renamedB = true }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let body: String
        switch url.lastPathComponent {
        case "allData.json":
            guard changeChecks else { throw JiraError.notFound }
            let etag = renamedB ? "v2" : "v1"
            let changed = value("etag") == etag ? "" : ",\"issuesData\":{}"
            body = "{\"rapidViewId\":1,\"etagData\":{\"rapidViewId\":1,\"etag\":\"\(etag)\"}\(changed)}"
        case "board": body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Board","type":"kanban"}]}"#
        case "configuration": body = #"{"id":1,"name":"Board","columnConfig":{"columns":[{"name":"Active","statuses":[{"id":"10"}]}]}}"#
        case "editmodel.json":
            let base = #""swimlanesConfig":{"rapidViewId":1,"swimlaneStrategy":"custom","swimlanes":[{"id":1,"name":"First","query":"labels = first","isDefault":false},{"id":2,"name":"Second","query":"labels = second","isDefault":false},{"id":3,"name":"Default","query":"","isDefault":true}]}"#
            body = "{" + (missingProjectedSettings && value("expand") != nil ? "" : #""oldDoneIssuesCutoff":"NONE","isKanPlanEnabled":false,"#) + base + "}"
        case "issue":
            let jql = value("jql")!
            if failLane && jql.contains("labels = second") { throw URLError(.notConnectedToInternet) }
            var ids = jql.contains("labels = first") ? ["A"] : jql.contains("labels = second") ? ["B", "A"] : ["C", "B", "A"]
            if removedB { ids.removeAll { $0 == "B" } }
            let offset = Int(value("startAt")!)!
            let source = repeatPage && offset > 0 ? 0 : offset
            let membership = value("fields") == "status"
            let cards = ids.dropFirst(source).prefix(1).map { id in
                let title = renamedB && id == "B" ? "Renamed B" : "Full card \(id)"
                let summary = membership ? "" : "\"summary\":\"\(title)\","
                return "{\"id\":\"\(id)\",\"key\":\"EX-\(id)\",\"fields\":{\(summary)\"assignee\":null,\"status\":{\"id\":\"10\",\"name\":\"Active\"}}}"
            }
            let total = unknownTotals ? "" : "\"total\":\(ids.count),"
            body = "{\"startAt\":\(offset),\"maxResults\":1,\(total)\"issues\":[\(cards.joined(separator: ","))]}"
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
