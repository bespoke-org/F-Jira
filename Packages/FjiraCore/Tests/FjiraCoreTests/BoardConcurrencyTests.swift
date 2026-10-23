import Foundation
import XCTest
@testable import FjiraCore

@MainActor
final class BoardConcurrencyTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com")

    func testRefreshUsesRollingPoolOf32CollectionsAndPublishesOnlyWhenComplete() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let configuration = Data(ConcurrentBoardTransport.configuration.utf8)
        let oldPage = Data(ConcurrentBoardTransport.page(key: "OLD-1", status: "10").utf8)
        let board = JiraBoard(id: 1, name: "Team", type: "kanban")
        let saved = CachedBoard(board: board,
            configuration: try JSONDecoder().decode(BoardConfiguration.self, from: configuration),
            configurationResponse: configuration,
            pages: [CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: oldPage),
                                    response: oldPage, fetchedAt: Date())],
            isComplete: true, fetchedAt: Date())
        try await cache.saveBoard(saved, site: site.identifier, account: "alice")
        let transport = ConcurrentBoardTransport()
        let reader = BoardReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("10000")

        // No request can finish until released: a sequential implementation stalls here.
        try await eventually { await transport.started.count == 32 }
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["OLD-1"])
        await transport.release(1)
        try await eventually { await transport.started.count == 33 }
        await transport.release(32)
        try await eventually { await transport.started.count == 34 }
        for index in 2..<32 { await transport.release(index) }
        await transport.release(33)
        try await eventually { await transport.finished.count == 33 }
        XCTAssertTrue(reader.isLoading)
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["OLD-1"])
        await transport.release(0)
        try await eventually { !reader.isLoading }

        let maximum = await transport.maximumActive
        let started = await transport.started
        XCTAssertEqual(maximum, 32)
        XCTAssertEqual(started.sorted(), Array(0..<34))
        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(reader.lanes.map { $0.columns.flatMap(\.issues).map(\.key) },
                       (0..<34).map { ["CELL-\($0)"] })
        let restored = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(Set(restored?.board.issues.map(\.key) ?? []), Set((0..<34).map { "CELL-\($0)" }))
    }

    func testResetCancelsAllConcurrentRequestsWithoutPublishingOrStartingMore() async throws {
        let transport = ConcurrentBoardTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("10000")
        try await eventually { await transport.started.count == 32 }
        reader.reset()
        try await eventually { await transport.cancelled == 32 }
        let started = await transport.started
        XCTAssertEqual(started.count, 32)
        XCTAssertNil(reader.snapshot)
        XCTAssertFalse(reader.isLoading)
        XCTAssertNil(reader.errorMessage)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for concurrent board requests")
        throw URLError(.timedOut)
    }
}

private actor ConcurrentBoardTransport: JiraTransport {
    static let configuration = #"{"id":1,"name":"Team","columnConfig":{"columns":[{"name":"Active","statuses":[{"id":"10"}]},{"name":"Done","statuses":[{"id":"20"}]}]}}"#
    private(set) var started: [Int] = []
    private(set) var finished = Set<Int>()
    private(set) var maximumActive = 0
    private(set) var cancelled = 0
    private var active = 0
    private var released = Set<Int>()

    func release(_ cell: Int) { released.insert(cell) }

    static func page(key: String, status: String) -> String {
        """
        {"startAt":0,"maxResults":50,"total":1,"issues":[{"id":"\(key)","key":"\(key)",
        "fields":{"summary":"Card","status":{"id":"\(status)","name":"Status"}}}]}
        """
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "board":
            body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Team","type":"kanban"}]}"#
        case "configuration": body = Self.configuration
        case "editmodel.json":
            let lanes = (0..<33).map { index in
                "{\"id\":\(index),\"name\":\"Lane \(index)\",\"query\":\"labels = lane\(index)\",\"isDefault\":false}"
            } + [#"{"id":33,"name":"Other","query":"","isDefault":true}"#]
            body = "{\"swimlanesConfig\":{\"rapidViewId\":1,\"swimlaneStrategy\":\"custom\",\"swimlanes\":[\(lanes.joined(separator: ","))]}}"
        case "issue":
            let jql = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "jql" }!.value!
            let lane = (0..<33).first { jql.contains("AND (labels = lane\($0))") }
            let cell = lane.map { $0 + 1 } ?? 0
            started.append(cell)
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            do {
                while !released.contains(cell) { try await Task.sleep(for: .milliseconds(5)) }
                try Task.checkCancellation()
            } catch {
                cancelled += 1
                throw error
            }
            finished.insert(cell)
            let cards = (lane.map { [$0] } ?? Array(0..<34)).map { index in
                "{\"id\":\"CELL-\(index)\",\"key\":\"CELL-\(index)\",\"fields\":{\"summary\":\"Card\",\"status\":{\"id\":\"\(index % 2 == 0 ? "10" : "20")\",\"name\":\"Status\"}}}"
            }
            body = "{\"startAt\":0,\"maxResults\":100,\"total\":\(cards.count),\"issues\":[\(cards.joined(separator: ","))]}"
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
