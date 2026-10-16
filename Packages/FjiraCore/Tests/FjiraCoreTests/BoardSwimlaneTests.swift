import Foundation
import XCTest
@testable import FjiraCore

final class BoardSwimlaneTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com/jira")

    func testCustomLanesKeepServerOrderAndExcludeEarlierMatches() throws {
        let config = try JSONDecoder().decode(SwimlaneConfiguration.self, from: Data(SwimlaneFixture.configuration.utf8))
        let lanes = try config.lanes()
        XCTAssertEqual(lanes.map(\.name), ["Expedite", "Regular work", "Improvements", "Everything else"])
        XCTAssertEqual(lanes[0].filter, "(priority = Blocker)")
        XCTAssertEqual(lanes[1].filter, "(issuetype = Task) AND NOT ((priority = Blocker))")
        XCTAssertEqual(lanes[2].filter, "(issuetype = Improvement) AND NOT ((priority = Blocker) OR (issuetype = Task))")
        XCTAssertEqual(lanes[3].filter, "NOT ((priority = Blocker) OR (issuetype = Task) OR (issuetype = Improvement))")
        XCTAssertTrue(lanes[3].isDefault)
    }

    func testOrderingIsIgnoredWithoutChangingQuotedText() {
        XCTAssertEqual(SwimlaneConfiguration.withoutOrdering(#"summary ~ "order by" ORDER BY updated DESC"#), #"summary ~ "order by""#)
        XCTAssertEqual(SwimlaneConfiguration.withoutOrdering("priority = Blocker order by Rank"), "priority = Blocker")
    }

    func testUnsupportedOrIncompleteConfigurationDoesNotSilentlyFlattenGroups() throws {
        for json in [
            #"{"rapidViewId":1,"swimlaneStrategy":"epic","swimlanes":[]}"#,
            #"{"rapidViewId":1,"swimlaneStrategy":"custom","swimlanes":[]}"#,
            #"{"rapidViewId":1,"swimlaneStrategy":"custom","swimlanes":[{"id":1,"name":"Lane","query":"","isDefault":false}]}"#
        ] {
            let config = try JSONDecoder().decode(SwimlaneConfiguration.self, from: Data(json.utf8))
            XCTAssertThrowsError(try config.lanes())
        }
    }

    func testSettingsUseReadOnlyContextAwareEndpointAndRetainResponse() async throws {
        let transport = SwimlaneTransport()
        let result = try await JiraClient(transport: transport).boardSwimlanes(site: site, token: "test-token", boardID: 1)
        XCTAssertEqual(result.lanes.count, 4)
        XCTAssertEqual(result.completedIssuesCutoff, "-1w")
        XCTAssertTrue(result.kanbanBacklogEnabled)
        XCTAssertFalse(result.response.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.path, "/jira/rest/greenhopper/1.0/rapidviewconfig/editmodel.json")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    @MainActor
    func testReaderKeepsGroupsSeparateWithIndependentPaginationAndOfflineRestoration() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let transport = SwimlaneTransport()
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(reader.snapshot?.configuration.columnConfig.columns.map(\.name), ["Active", "Done"])
        XCTAssertEqual(reader.lanes.first?.columns.count, 2)
        XCTAssertEqual(reader.lanes.filter { !$0.isEmpty }.map(\.name), ["Expedite", "Regular work", "Improvements"])
        XCTAssertEqual(reader.lanes[0].columns[1].issues.count, 50)
        XCTAssertEqual(reader.lanes[0].total, 61)
        XCTAssertEqual(reader.lanes[1].columns[1].issues.count, 0)
        XCTAssertEqual(reader.lanes[2].columns[0].issues.count, 1)
        reader.loadMore(column: reader.lanes[0].columns[1].id)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.lanes[0].columns[1].issues.count, 60)
        XCTAssertFalse(reader.lanes[0].columns[1].hasMore)
        XCTAssertEqual(reader.lanes[1].columns[0].issues.count, 1)
        let requests = await transport.requests
        let paging = try XCTUnwrap(requests.last { $0.url?.lastPathComponent == "issue" })
        let query = URLComponents(url: paging.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "startAt" }?.value, "50")
        XCTAssertTrue(query.first { $0.name == "jql" }!.value!.contains("status in (20)"))
        XCTAssertTrue(query.first { $0.name == "jql" }!.value!.contains("AND ((priority = Blocker))"))
        XCTAssertTrue(query.first { $0.name == "jql" }!.value!.contains("AND (status not in (20) OR updated >= -1w)"))
        let saved = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(saved?.board.laneSnapshots?.count, 4)
        XCTAssertNotNil(saved?.board.swimlanesResponse)
        XCTAssertEqual(saved?.board.lanes()[0].columns[1].issues.count, 60)
        reader.reset()
        let offline = BoardReader(site: site, account: "alice", cache: cache,
                                  client: JiraClient(transport: SwimlaneTransport(offline: true))) { "token" }
        offline.openProject("10000")
        try await eventually { offline.snapshot != nil && !offline.isLoading }
        XCTAssertEqual(offline.lanes.filter { !$0.isEmpty }.map(\.name), ["Expedite", "Regular work", "Improvements"])
        XCTAssertEqual(offline.lanes[0].columns[1].issues.count, 50)
        offline.loadMore(column: 1)
        try await eventually { offline.loadingColumnID == nil }
        XCTAssertEqual(offline.lanes[0].columns[1].issues.count, 60)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.assignees.map(\.identifier), ["user-1", "user-2", "user-3"])
        offline.selectedAssigneeID = "user-2"
        XCTAssertEqual(offline.lanes.filter { !$0.isEmpty }.map(\.name), ["Regular work"])
        XCTAssertEqual(offline.columns.flatMap(\.issues).count, 1)
        XCTAssertEqual(offline.assignees.count, 3, "People from other swimlanes must remain selectable")
        offline.selectedAssigneeID = nil
        XCTAssertEqual(offline.lanes.filter { !$0.isEmpty }.count, 3)
        offline.reset()
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for swimlane state")
    }
}

private enum SwimlaneFixture {
    static let configuration = #"{"rapidViewId":1,"swimlaneStrategy":"custom","swimlanes":[{"id":99,"name":"Everything else","query":"","isDefault":true},{"id":10,"name":"Expedite","query":"priority = Blocker","isDefault":false},{"id":20,"name":"Regular work","query":"issuetype = Task","isDefault":false},{"id":30,"name":"Improvements","query":"issuetype = Improvement ORDER BY updated DESC","isDefault":false}]}"#
    static let board = #"{"id":1,"name":"Team","columnConfig":{"columns":[{"name":"Kanban backlog","statuses":[{"id":"1"}]},{"name":"Active","statuses":[{"id":"10"}]},{"name":"Done","statuses":[{"id":"20"}]}]}}"#
}

private actor SwimlaneTransport: JiraTransport {
    private(set) var requests: [URLRequest] = []
    let offline: Bool
    init(offline: Bool = false) { self.offline = offline }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "board": body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Team","type":"kanban"}]}"#
        case "configuration": body = SwimlaneFixture.board
        case "editmodel.json": body = "{\"isKanPlanEnabled\":true,\"oldDoneIssuesCutoff\":\"-1w\",\"swimlanesConfig\":\(SwimlaneFixture.configuration)}"
        case "issue":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let jql = query.first { $0.name == "jql" }!.value!
            let offset = Int(query.first { $0.name == "startAt" }!.value!)!
            let lane: Int
            if jql.contains("AND ((issuetype = Improvement)") { lane = 3 }
            else if jql.contains("AND ((issuetype = Task)") { lane = 2 }
            else if jql.contains("AND ((priority = Blocker))") { lane = 1 }
            else { lane = 4 }
            let status = jql.hasPrefix("status in (20)") ? "20" : "10"
            let total = lane == 4 ? 0 : (status == "10" ? 1 : (lane == 1 ? 60 : 0))
            let end = min(total, offset + 50)
            let issues = (offset..<max(offset, end)).map { index in
                "{\"id\":\"\(lane)-\(status)-\(index)\",\"key\":\"EX-\(lane)-\(index)\",\"fields\":{\"summary\":\"Fixture\",\"status\":{\"name\":\"Status\",\"id\":\"\(status)\"},\"assignee\":{\"name\":\"user-\(lane)\",\"displayName\":\"Person \(lane)\"}}}"
            }
            body = "{\"startAt\":\(offset),\"maxResults\":50,\"total\":\(total),\"issues\":[\(issues.joined(separator: ","))]}"
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
