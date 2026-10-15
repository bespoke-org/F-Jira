import Foundation
import XCTest
@testable import FjiraCore

final class IssueConsistencyTests: XCTestCase {
    private let site = "https://jira.example.com"
    private let account = "alice"
    private let query = try! ProjectQuery(projectID: "10000", input: "")

    func testNewerDetailCorrectsPreviouslyCachedBoardAndSearchOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        var originalBoard = try Fixture.board(page: stale)
        let doneFields = try Fixture.page(status: "20", updated: Fixture.new).page.issues[0].fields
        let residents = [JiraIssue(id: "103", key: "EX-3", fields: doneFields),
                         JiraIssue(id: "102", key: "EX-2", fields: doneFields)]
        let donePage = IssuePage(startAt: 0, maxResults: 50, total: 2, issues: residents, warningMessages: nil)
        originalBoard.columnPages?[1] = [CachedIssuePage(page: donePage,
            response: try JSONEncoder().encode(donePage), fetchedAt: Date())]
        try await cache.saveBoard(originalBoard, site: site, account: account)
        try await cache.savePage(stale, site: site, account: account, query: query)
        try await cache.saveIssue(Fixture.detail(status: "20", updated: Fixture.new), site: site, account: account)
        let reopened = try ConnectionCache(path: path)
        let board = try await reopened.loadBoardPresentation(site: site, account: account, boardID: 1)?.board
        let search = try await reopened.loadSearch(site: site, account: account, query: query)
        XCTAssertEqual(board?.columns().map { $0.issues.map(\.key) }, [[], ["EX-3", "EX-2", "RDCR-4749"]],
                       "A locally moved card belongs after the destination column's existing cards")
        XCTAssertEqual(search?.issues.first?.fields.status?.id, "20")
        XCTAssertEqual(board?.columns().map(\.total), [0, 3])
        XCTAssertEqual(board?.columns(limits: [1: 2])[1].issues.map(\.key), ["EX-3", "EX-2"])
        XCTAssertEqual(board?.columns(limits: [1: 2])[1].hasMore, true)
        XCTAssertEqual(board?.nextStartAt(column: 0), 1, "Moving a card must not change server pagination")
        XCTAssertEqual(board?.columnPages?[0]?.first?.response, stale.response)
    }

    func testFreshDownloadCannotRollBackNewerJiraRevision() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(Fixture.detail(status: "20", updated: Fixture.new), site: site, account: account)
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        try await cache.saveBoard(Fixture.board(page: stale), site: site, account: account)
        try await cache.savePage(stale, site: site, account: account, query: query)
        try await cache.saveIssue(Fixture.detail(status: "10", updated: Fixture.old, description: "stale body"), site: site, account: account)
        let board = try await cache.loadBoardPresentation(site: site, account: account, boardID: 1)?.board
        let search = try await cache.loadSearch(site: site, account: account, query: query)
        let detail = try await cache.loadIssue(site: site, account: account, id: "100")
        XCTAssertEqual(board?.issues.first?.fields.status?.id, "20")
        XCTAssertEqual(search?.issues.first?.fields.status?.id, "20")
        XCTAssertEqual(detail?.issue.fields.status?.id, "20")
        XCTAssertEqual(detail?.issue.fields.description, "correct body")
    }

    func testNewerSearchCorrectsDetailWithoutPreventingFullBodyRefresh() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(Fixture.detail(status: "10", updated: Fixture.old, description: "old body"), site: site, account: account)
        try await cache.savePage(Fixture.page(status: "20", updated: Fixture.new), site: site, account: account, query: query)
        let projected = try await cache.loadIssue(site: site, account: account, id: "100")
        XCTAssertEqual(projected?.issue.fields.status?.id, "20")
        XCTAssertEqual(projected?.issue.fields.description, "old body")
        try await cache.saveIssue(Fixture.detail(status: "20", updated: Fixture.new), site: site, account: account)
        let refreshed = try await cache.loadIssue(site: site, account: account, id: "100")
        XCTAssertEqual(refreshed?.issue.fields.description, "correct body")
    }

    func testKnownIssueStateIsScopedToSiteAndAccount() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        try await cache.saveIssue(Fixture.detail(status: "20", updated: Fixture.new), site: site, account: account)
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        for (otherSite, otherAccount) in [(site, "bob"), ("https://other.example.com", account)] {
            try await cache.saveBoard(Fixture.board(page: stale), site: otherSite, account: otherAccount)
            let saved = try await cache.loadBoardPresentation(site: otherSite, account: otherAccount, boardID: 1)
            XCTAssertEqual(saved?.board.issues.first?.fields.status?.id, "10")
        }
    }
    func testLegacyDetailIsUsedBeforeAnyNewNetworkResponse() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let board = try Fixture.board(page: Fixture.page(status: "10", updated: Fixture.old))
        let detail = try Fixture.detail(status: "20", updated: Fixture.new)
        let payloads = ["board:1": try JSONEncoder().encode(board), "issue-detail:100": try JSONEncoder().encode(detail)]
        try await cache.database.write { db in
            for (resource, data) in payloads {
                try db.execute(sql: "INSERT INTO response_cache (site, account, resource, payload) VALUES (?, ?, ?, ?)",
                               arguments: ["https://jira.example.com", "alice", resource, data])
            }
        }
        let restored = try await cache.loadBoardPresentation(site: site, account: account, boardID: 1)
        XCTAssertEqual(restored?.board.columns().map { $0.issues.map(\.key) }, [[], ["RDCR-4749"]])
    }

    func testDuplicatePagesChooseNewestAndKeepOffsetsAndUnknownTotals() throws {
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        let fresh = try Fixture.page(status: "20", updated: Fixture.new)
        var board = try Fixture.board(page: stale)
        board.columnPages?[1] = [fresh]
        XCTAssertEqual(board.issues.count, 1)
        XCTAssertEqual(board.columns().map { $0.issues.count }, [0, 1])
        board.columnPages?[0] = [CachedIssuePage(page: IssuePage(startAt: 0, maxResults: 1, total: 20,
            issues: stale.page.issues, warningMessages: nil), response: stale.response, fetchedAt: Date())]
        let corrected = board.reconciling(fresh.page.issues)
        XCTAssertNil(corrected.columns()[0].total, "An incomplete column cannot claim the stale index total is exact")
        XCTAssertTrue(corrected.columns()[0].hasMore)
        XCTAssertEqual(corrected.nextStartAt(column: 0), 1)
    }

    func testCorrectedOldDoneIssueRemainsOutsideBoardCutoffInSwimlane() throws {
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        let fresh = try Fixture.page(status: "20", updated: Fixture.new)
        var child = try Fixture.board(page: stale)
        child.completedIssuesCutoff = "-1d"
        var board = child
        board.laneSnapshots = [CachedBoardLane(lane: BoardSwimlane(id: 1, name: "Tasks", query: "", isDefault: true, filter: ""), board: child)]
        let corrected = board.reconciling(fresh.page.issues)
        XCTAssertEqual(corrected.lanes().first?.columns.map { $0.issues.count }, [0, 0])
        XCTAssertEqual(corrected.lanes().first?.total, 0)
    }

    func testDirectLookupBreaksEqualRevisionTieButCannotRollBackNewerState() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let review = try Fixture.page(status: "10", updated: Fixture.new).page.issues
        let done = try Fixture.page(status: "20", updated: Fixture.new).page.issues
        _ = try await cache.reconcileIssues(review, site: site, account: account)
        _ = try await cache.reconcileIssues(done, site: site, account: account, verified: true)
        let stale = try await cache.reconcileIssues(review, site: site, account: account)
        XCTAssertEqual(stale.issues.first?.fields.status?.id, "20")
        let older = try Fixture.page(status: "10", updated: Fixture.old).page.issues
        let verifiedOld = try await cache.reconcileIssues(older, site: site, account: account, verified: true)
        XCTAssertEqual(verifiedOld.issues.first?.fields.status?.id, "20")
        let unknown = try Fixture.page(status: "10", updated: "invalid").page.issues
        let missingDate = try await cache.reconcileIssues(unknown, site: site, account: account, verified: true)
        XCTAssertEqual(missingDate.issues.first?.fields.status?.id, "20")
    }

    func testRevisionComparisonHandlesTimeZonesAndWholeSeconds() throws {
        let first = try Fixture.page(status: "10", updated: "2026-10-09T10:24:57+0300").page.issues[0]
        let same = try Fixture.page(status: "20", updated: "2026-10-09T07:24:57.000Z").page.issues[0]
        let later = try Fixture.page(status: "20", updated: "2026-10-09T07:24:57.643+00:00").page.issues[0]
        XCTAssertNotNil(first.revision)
        XCTAssertEqual(first.revision, same.revision)
        XCTAssertEqual(first.accepting(same, onEqual: false).statusIdentity, "10")
        XCTAssertEqual(first.accepting(later, onEqual: false).statusIdentity, "20")
    }

    @MainActor
    func testBoardRefreshVerifiesOnlyConflictsAndRetainsKnownStateIfVerificationFails() async throws {
        for failure in [false, true] {
            let cache = try ConnectionCache(path: ":memory:")
            try await cache.saveIssue(Fixture.detail(status: "20", updated: Fixture.new), site: site, account: account)
            let transport = ConsistencyTransport(failVerification: failure)
            let reader = BoardReader(site: try JiraSite(site), account: account, cache: cache,
                                     client: JiraClient(transport: transport)) { "token" }
            reader.openProject("10000")
            try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
            XCTAssertEqual(reader.columns.map { $0.issues.map(\.id) }, [["101"], ["100"]])
            XCTAssertNil(reader.errorMessage)
            let requests = await transport.requests
            let direct = requests.filter { $0.url?.path.contains("/api/2/issue/") == true }
            XCTAssertEqual(direct.count, 1)
            XCTAssertEqual(direct.first?.url?.lastPathComponent, "100")
            XCTAssertEqual(direct.first?.httpMethod, "GET")
            let fields = direct.first.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
            XCTAssertEqual(fields?.first { $0.name == "fields" }?.value, "summary,status,assignee,priority,updated,issuetype")
            reader.reset()
        }
    }

    @MainActor
    func testConsistentBoardMakesNoPerCardRequests() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let transport = ConsistencyTransport()
        let reader = BoardReader(site: try JiraSite(site), account: account, cache: cache,
                                 client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path.contains("/api/2/issue/") == true })
        reader.reset()
    }

    @MainActor
    func testOpeningNewerDetailImmediatelyMovesVisibleBoardAndSearchThenSurvivesRefresh() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let transport = ConsistencyTransport()
        let client = JiraClient(transport: transport)
        let board = BoardReader(site: try JiraSite(site), account: account, cache: cache, client: client) { "token" }
        let issue = IssueReader(site: try JiraSite(site), account: account, cache: cache, client: client) { "token" }
        let stale = try Fixture.page(status: "10", updated: Fixture.old)
        var search = CachedSearch(query: query, generation: UUID(), pages: [stale])
        issue.onIssueUpdate = { latest in
            board.applyKnownIssues([latest])
            search = search.reconciling([latest])
        }
        board.openProject("10000")
        try await eventually { board.snapshot != nil && !board.isLoading && !board.isLoadingBoards }
        XCTAssertEqual(board.columns.map { $0.issues.count }, [2, 0])
        issue.open(stale.page.issues[0])
        await issue.currentTask?.value
        XCTAssertEqual(board.columns.map { $0.issues.map(\.id) }, [["101"], ["100"]])
        XCTAssertEqual(search.issues.first?.statusIdentity, "20")
        board.refresh()
        try await eventually { !board.isLoading }
        XCTAssertEqual(board.columns.map { $0.issues.map(\.id) }, [["101"], ["100"]])
        issue.close()
        board.reset()
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Reader did not reach the expected state")
    }

}

private enum Fixture {
    static let old = "2026-10-08T10:04:57.000+0300"
    static let new = "2026-10-09T10:24:57.643+0300"
    static let configuration = #"{"id":1,"name":"Team","columnConfig":{"columns":[{"name":"Review","statuses":[{"id":"10"}]},{"name":"Done","statuses":[{"id":"20"}]}]}}"#

    static func json(status: String, updated: String, description: String = "correct body") -> String {
        """
        {"id":"100","key":"RDCR-4749","fields":{"summary":"Example","description":"\(description)","status":{"id":"\(status)","name":"\(status == "20" ? "Done" : "Review")"},"updated":"\(updated)"}}
        """
    }

    static func page(status: String, updated: String) throws -> CachedIssuePage {
        let response = Data("{\"startAt\":0,\"maxResults\":50,\"total\":1,\"issues\":[\(json(status: status, updated: updated))]}".utf8)
        return CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: response), response: response, fetchedAt: Date())
    }

    static func detail(status: String, updated: String, description: String = "correct body") throws -> CachedIssueDetail {
        let response = Data(json(status: status, updated: updated, description: description).utf8)
        return CachedIssueDetail(issue: try JSONDecoder().decode(JiraIssueDetail.self, from: response), response: response,
                                 fetchedAt: Date(), generation: UUID(), commentPages: [], previousComments: [])
    }

    static func board(page: CachedIssuePage) throws -> CachedBoard {
        let data = Data(configuration.utf8)
        var board = CachedBoard(board: JiraBoard(id: 1, name: "Team", type: "kanban"),
            configuration: try JSONDecoder().decode(BoardConfiguration.self, from: data), configurationResponse: data,
            pages: [], isComplete: true, fetchedAt: Date(timeIntervalSince1970: 1_792_000_000))
        board.columnPages = [0: [page], 1: [CachedIssuePage(page: IssuePage(startAt: 0, maxResults: 50, total: 0, issues: [], warningMessages: nil), response: Data(), fetchedAt: Date())]]
        return board
    }
}

private actor ConsistencyTransport: JiraTransport {
    private(set) var requests: [URLRequest] = []
    let failVerification: Bool
    init(failVerification: Bool = false) { self.failVerification = failVerification }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "board":
            body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Team","type":"kanban"}]}"#
        case "configuration": body = Fixture.configuration
        case "editmodel.json":
            body = #"{"swimlanesConfig":{"rapidViewId":1,"swimlaneStrategy":"none","swimlanes":[]}}"#
        case "issue":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let done = query.first { $0.name == "jql" }!.value!.hasPrefix("status in (20)")
            let review = Fixture.json(status: "10", updated: Fixture.old)
            let other = review.replacingOccurrences(of: "100", with: "101").replacingOccurrences(of: "RDCR-4749", with: "EX-2")
            body = done ? #"{"startAt":0,"maxResults":50,"total":0,"issues":[]}"#
                : "{\"startAt\":0,\"maxResults\":50,\"total\":2,\"issues\":[\(review),\(other)]}"
        case "100":
            if failVerification { throw URLError(.notConnectedToInternet) }
            body = Fixture.json(status: "20", updated: Fixture.new)
        case "remotelink": body = "[]"
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
