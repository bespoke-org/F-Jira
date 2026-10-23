import Foundation
import XCTest
@testable import FjiraCore

final class BoardTests: XCTestCase {
    private let site = try! JiraSite("https://jira.example.com/jira")

    func testBoardDiscoveryPaginatesUsingActualPageSizeAndPreservesContextPath() async throws {
        let transport = StubTransport([
            (200, #"{"startAt":0,"maxResults":2,"isLast":false,"values":[{"id":1,"name":"Team","type":"kanban"},{"id":2,"name":"Sprint","type":"scrum"}]}"#),
            (200, #"{"startAt":2,"maxResults":2,"isLast":true,"values":[{"id":3,"name":"Other","type":"kanban"}]}"#)
        ])
        let result = try await JiraClient(transport: transport).boards(site: site, token: "test-token", projectID: "10000")
        XCTAssertEqual(result.boards.map(\.id), [1, 2, 3])
        XCTAssertEqual(result.responses.count, 2)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/jira/rest/agile/1.0/board", "/jira/rest/agile/1.0/board"])
        XCTAssertEqual(requests.map { query($0, "startAt") }, ["0", "2"])
        XCTAssertTrue(requests.allSatisfy { query($0, "projectKeyOrId") == "10000" })
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    func testBoardIssuesRespectMappingsAndKanbanSubqueryWithoutOverridingRank() async throws {
        let transport = StubTransport([(200, BoardFixture.page())])
        let snapshot = try BoardFixture.snapshot()
        _ = try await JiraClient(transport: transport).boardIssues(site: site, token: "token", board: snapshot.board,
                                                                 configuration: snapshot.configuration, startAt: 0)
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/jira/rest/agile/1.0/board/1/issue")
        XCTAssertEqual(query(request, "jql"), "status in (10,11,20) AND (fixVersion in unreleasedVersions() OR fixVersion is EMPTY)")
        XCTAssertFalse(query(request, "jql")!.lowercased().contains("order by"))
        XCTAssertTrue(query(request, "fields")!.contains("issuetype"))
        XCTAssertEqual(snapshot.board.webURL(site: site).absoluteString, "https://jira.example.com/jira/secure/RapidBoard.jspa?rapidView=1")
    }

    func testScrumIncludesOnlyActiveSprintIssues() throws {
        let snapshot = try BoardFixture.snapshot()
        let scrum = JiraBoard(id: 1, name: "Sprint", type: "scrum")
        XCTAssertEqual(try snapshot.configuration.issueFilter(board: scrum), "status in (10,11,20) AND sprint in openSprints()")
    }

    func testColumnsUseStatusIDsPreserveRankAndFilterLocally() throws {
        let snapshot = try BoardFixture.snapshot(page: BoardFixture.page(issues: [
            BoardFixture.issue("EX-3", status: "11", summary: "Fix login", user: "alice"),
            BoardFixture.issue("EX-2", status: "10", summary: "Login page", user: "bob"),
            BoardFixture.issue("EX-1", status: "20", summary: "Release", user: nil),
            BoardFixture.issue("EX-4", status: "99", summary: "Unmapped", user: nil)
        ]))
        let columns = snapshot.columns()
        XCTAssertEqual(columns.map(\.configuration.name), ["In progress", "Done"])
        XCTAssertEqual(columns.map { $0.issues.map(\.key) }, [["EX-3", "EX-2"], ["EX-1"]])
        XCTAssertEqual(snapshot.columns(matching: "LOGIN", assignee: "alice").first?.issues.map(\.key), ["EX-3"])
        XCTAssertEqual(snapshot.columns(matching: "ex-2").first?.issues.map(\.key), ["EX-2"])
        XCTAssertTrue(snapshot.columns(matching: "absent").allSatisfy { $0.issues.isEmpty })
    }

    func testMalformedPaginationFailsInsteadOfLoopingOrPublishingIncompleteResults() async throws {
        for body in [
            #"{"startAt":0,"maxResults":50,"total":4,"isLast":false,"values":[]}"#,
            #"{"startAt":5,"maxResults":50,"isLast":true,"values":[]}"#
        ] {
            do {
                _ = try await JiraClient(transport: StubTransport([(200, body)])).boards(site: site, token: "token", projectID: "10000")
                XCTFail("Expected malformed pagination to fail")
            } catch { XCTAssertEqual(error as? SearchError, .inconsistentPagination) }
        }
    }

    func testBoardsAndImagesSurviveReopeningAndAreIsolated() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "cache.sqlite").path
        let cache = try ConnectionCache(path: path)
        let snapshot = try BoardFixture.snapshot()
        try await cache.saveBoard(snapshot, site: site.identifier, account: "alice")
        try await cache.saveBoards(CachedBoards(boards: [snapshot.board], fetchedAt: Date(), responses: []),
                                   site: site.identifier, account: "alice", project: "10000")
        try await cache.saveBoardSelection(1, site: site.identifier, account: "alice", project: "10000")
        let avatar = CachedAvatar(data: Data([1, 2, 3]), mimeType: "image/png", fetchedAt: Date())
        try await cache.saveAvatar(avatar, site: site.identifier, account: "alice", url: BoardFixture.iconURL)
        let reopened = try ConnectionCache(path: path)
        let restored = try await reopened.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(restored?.board.issues.map(\.key), ["EX-1"])
        XCTAssertEqual(restored?.board.configurationResponse, snapshot.configurationResponse)
        XCTAssertEqual(restored?.images[BoardFixture.iconURL.absoluteString]?.data, avatar.data)
        let list = try await reopened.loadBoards(site: site.identifier, account: "alice", project: "10000")
        XCTAssertEqual(list?.boards.map(\.id), [1])
        let selected = try await reopened.loadBoardSelection(site: site.identifier, account: "alice", project: "10000")
        XCTAssertEqual(selected, 1)
        let otherAccount = try await reopened.loadBoardPresentation(site: site.identifier, account: "bob", boardID: 1)
        let otherSite = try await reopened.loadBoardPresentation(site: "other", account: "alice", boardID: 1)
        let otherProject = try await reopened.loadBoards(site: site.identifier, account: "alice", project: "20000")
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherSite)
        XCTAssertNil(otherProject)
    }

    @MainActor
    func testCachedBoardAppearsBeforeNetworkAndSurvivesFailedRefresh() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let snapshot = try BoardFixture.snapshot()
        try await seed(cache, snapshots: [snapshot])
        let transport = BoardFixtureTransport(failIssues: true)
        await transport.holdConfiguration(1)
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil }
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["EX-1"])
        XCTAssertTrue(reader.isLoading, "Cached content must appear while the network request is still suspended")
        await transport.releaseConfiguration(1)
        try await eventually { !reader.isLoading && !reader.isLoadingBoards }
        XCTAssertTrue(reader.isOffline)
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["EX-1"])
        let saved = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(saved?.board.issues.map(\.key), ["EX-1"])
        reader.reset()
    }

    @MainActor
    func testAssigneePickerUsesAllCachedBoardCardsAndKeepsSelectionStableOffline() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let bob = BoardFixture.issue("BOB-1", summary: "Fix login", user: "bob")
            .replacingOccurrences(of: #""name":"bob""#, with: #""name":"bob-login","key":"bob-key""#)
        let issues = (0..<55).map { BoardFixture.issue("ALICE-\($0)") } + [
            bob,
            BoardFixture.issue("HIDDEN-1", status: "99", user: "carol"),
            BoardFixture.issue("UNASSIGNED-1", status: "20", user: nil)
        ]
        try await seed(cache, snapshots: [BoardFixture.snapshot(page: BoardFixture.page(issues: issues))])
        let reader = BoardReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: BoardFixtureTransport(failIssues: true))) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
        XCTAssertTrue(reader.isOffline)
        XCTAssertEqual(reader.columns.first?.issues.count, 50)
        XCTAssertEqual(reader.assignees.map(\.identifier), ["alice", "bob-key"],
                       "Include people beyond the visible page, but exclude cards outside the board's columns")

        reader.selectedAssigneeID = "bob-key"
        XCTAssertEqual(reader.columns.flatMap(\.issues).map(\.key), ["BOB-1"])
        reader.filterText = "absent"
        XCTAssertTrue(reader.columns.allSatisfy { $0.issues.isEmpty })
        XCTAssertEqual(reader.assignees.map(\.identifier), ["alice", "bob-key"],
                       "Filtering must not remove people from the picker")
        reader.filterText = "login"
        XCTAssertEqual(reader.columns.flatMap(\.issues).map(\.key), ["BOB-1"])

        reader.refresh()
        try await eventually { !reader.isLoading && !reader.isLoadingBoards }
        XCTAssertEqual(reader.selectedAssigneeID, "bob-key")
        XCTAssertEqual(reader.columns.flatMap(\.issues).map(\.key), ["BOB-1"])

        let reassigned = try JSONDecoder().decode(JiraIssue.self, from: Data(
            BoardFixture.issue("BOB-1", summary: "Fix login", user: "alice").utf8))
        reader.applyKnownIssues([reassigned])
        XCTAssertTrue(reader.columns.allSatisfy { $0.issues.isEmpty })
        XCTAssertEqual(reader.assignees.last?.identifier, "bob-key",
                       "Keep the selected person's name when their last task is reassigned")
        reader.selectedAssigneeID = nil
        XCTAssertEqual(reader.assignees.map(\.identifier), ["alice"])
        XCTAssertEqual(reader.columns.flatMap(\.issues).map(\.key), ["BOB-1"])
        reader.selectedAssigneeID = "alice"
        reader.selectBoard(2)
        XCTAssertNil(reader.selectedAssigneeID, "A different board starts with all assignees")
        reader.reset()
        XCTAssertTrue(reader.assignees.isEmpty)
    }

    @MainActor
    func testLateBoardResponseCannotReplaceNewSelectionAndMemoryIsImmediate() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        try await seed(cache, snapshots: [BoardFixture.snapshot(), BoardFixture.snapshot(id: 2)])
        let transport = BoardFixtureTransport()
        await transport.holdConfiguration(1)
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot?.board.id == 1 && !reader.isLoadingBoards }
        reader.selectBoard(2)
        try await eventually { reader.snapshot?.board.id == 2 && !reader.isLoading }
        await transport.releaseConfiguration(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reader.snapshot?.board.id, 2)
        reader.selectBoard(1)
        XCTAssertEqual(reader.snapshot?.board.id, 1, "Reopening a board in memory must not wait for SQLite or the network")
        reader.reset()
    }

    @MainActor
    func testPagesLoadOnDemandAndRefreshFailurePreservesDownloadedSnapshot() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let transport = BoardFixtureTransport()
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1"])
        reader.loadMore(column: 0)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1", "NEW-2"])
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "issue" }.map { query($0, "startAt") }, ["0", "0", "1"])
        await transport.failDoneColumn()
        reader.refresh()
        XCTAssertTrue(reader.isLoadingBoards)
        XCTAssertTrue(reader.isLoading)
        try await eventually { !reader.isLoading && !reader.isLoadingBoards }
        let refreshedRequests = await transport.requests
        XCTAssertEqual(refreshedRequests.filter { $0.url?.lastPathComponent == "board" }.count, 2,
                       "Refreshing the current board must also fetch the available board list")
        XCTAssertNil(reader.listError, "A failed issue refresh must not prevent the board list from refreshing")
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1", "NEW-2"])
        XCTAssertEqual(reader.snapshot?.isComplete, true)
        XCTAssertNotNil(reader.errorMessage)
        let saved = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(saved?.board.issues.map(\.key), ["NEW-1", "NEW-2"])
        reader.reset()
    }

    @MainActor
    func testFirstDownloadKeepsCardsIfAnotherColumnFails() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let transport = BoardFixtureTransport()
        await transport.failDoneColumn()
        let reader = BoardReader(site: site, account: "alice", cache: cache, client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.errorMessage != nil && !reader.isLoading }
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1"])
        XCTAssertEqual(reader.snapshot?.isComplete, false)
        let saved = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(saved?.board.issues.map(\.key), ["NEW-1"])
        XCTAssertEqual(saved?.board.isComplete, false)
        reader.reset()
    }

    @MainActor
    func testLargeBoardInitiallyLoadsAtMost50CardsPerColumn() async throws {
        let transport = LargeBoardTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        XCTAssertEqual(reader.columns.first?.issues.count, 1, "Small columns must not be hidden behind Done's pages")
        XCTAssertEqual(reader.columns.last?.issues.count, 50, "Do not load all 550 Done cards on opening")
        let requests = await transport.issueRequests
        XCTAssertLessThanOrEqual(requests.count, 2, "Only the first page of each column should be requested")
        XCTAssertEqual(reader.columns.last?.total, 550)
        XCTAssertEqual(reader.columns.last?.hasMore, true)
        reader.loadMore(column: 1)
        reader.loadMore(column: 1) // Repeated appearance callbacks must not duplicate requests.
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.columns.last?.issues.count, 100)
        let afterScroll = await transport.issueRequests
        XCTAssertEqual(afterScroll.count, 3)
        XCTAssertEqual(query(afterScroll.last!, "startAt"), "50")
        XCTAssertTrue(query(afterScroll.last!, "jql")!.hasPrefix("status in (20)"))
        reader.reset()
    }

    @MainActor
    func testLegacyCachedDoneColumnReveals50AtATimeOffline() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let old = try BoardFixture.snapshot(page: BoardFixture.page(issues:
            (0..<550).map { BoardFixture.issue("DONE-\($0)", status: "20") }))
        try await seed(cache, snapshots: [old])
        let reader = BoardReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: BoardFixtureTransport(failIssues: true))) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        XCTAssertTrue(reader.isOffline)
        XCTAssertEqual(reader.columns.last?.issues.count, 50)
        reader.loadMore(column: 1)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.columns.last?.issues.count, 100)
        XCTAssertEqual(reader.snapshot?.issues.count, 550, "Display limits must not delete cached cards")
        reader.filterText = "DONE-549"
        XCTAssertEqual(reader.columns.last?.issues.map(\.key), ["DONE-549"], "Local filtering includes all downloaded cards")
        reader.filterText = ""
        XCTAssertEqual(reader.columns.last?.issues.count, 50)
        reader.reset()
    }

    @MainActor
    func testRefreshRetainsOlderCachedCardsUntilTheirColumnHasBeenFullyFetched() async throws {
        let cache = try ConnectionCache(path: ":memory:")
        let old = try BoardFixture.snapshot(page: BoardFixture.page(issues:
            (0..<550).map { BoardFixture.issue("DONE-\($0)", status: "20") }))
        try await seed(cache, snapshots: [old])
        let transport = LargeBoardTransport()
        let reader = BoardReader(site: site, account: "alice", cache: cache,
                                 client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot?.columnPages != nil && !reader.isLoading }
        XCTAssertEqual(reader.columns.last?.issues.count, 50)
        let restored = try await cache.loadBoardPresentation(site: site.identifier, account: "alice", boardID: 1)
        XCTAssertEqual(restored?.board.issues.filter { $0.status == "Same name" }.count, 551)
        reader.loadMore(column: 1)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.columns.last?.issues.count, 100)
        XCTAssertEqual(reader.columns.last?.containsOlderIssues, false)
        XCTAssertEqual(reader.snapshot?.retainedIssues?.count, 450)
        reader.reset()
    }

    @MainActor
    func testFailedNextPageCanRetryWithoutSkippingCards() async throws {
        let transport = LargeBoardTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading }
        await transport.setFailNextPage(true)
        reader.loadMore(column: 1)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.columns.last?.issues.count, 50)
        XCTAssertNotNil(reader.columnErrors[1])
        await transport.setFailNextPage(false)
        reader.loadMore(column: 1)
        try await eventually { reader.loadingColumnID == nil }
        XCTAssertEqual(reader.columns.last?.issues.count, 100)
        XCTAssertNil(reader.columnErrors[1])
        let requests = await transport.issueRequests
        XCTAssertEqual(requests.suffix(2).map { query($0, "startAt") }, ["50", "50"])
        reader.reset()
    }

    @MainActor
    func testAutomaticRefreshUpdatesOnlySelectedBoardAndPreservesFilters() async throws {
        let transport = BoardFixtureTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
        let previous = reader.snapshot?.fetchedAt
        reader.filterText = "NEW"
        reader.selectedAssigneeID = "alice"
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(20)) }
        defer { automatic.cancel() }
        try await eventually { reader.snapshot?.fetchedAt != previous && !reader.isLoading }
        automatic.cancel()
        await automatic.value
        XCTAssertEqual(reader.filterText, "NEW")
        XCTAssertEqual(reader.selectedAssigneeID, "alice")
        XCTAssertEqual(reader.columns.first?.issues.map(\.key), ["NEW-1"])
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "board" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "configuration" }.count, 1, "Automatic checks reuse recent settings")
        try await Task.sleep(for: .milliseconds(60))
        let afterCancellation = await transport.requests
        XCTAssertEqual(afterCancellation.count, requests.count)
    }

    @MainActor
    func testAutomaticRefreshDoesNotInterruptManualRefreshOrPaging() async throws {
        for paging in [false, true] {
            let transport = BoardFixtureTransport()
            let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                     client: JiraClient(transport: transport)) { "token" }
            defer { reader.reset() }
            reader.openProject("10000")
            try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
            await transport.holdIssueRequests(true)
            if paging { reader.loadMore(column: 0) } else { reader.refresh() }
            let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(10)) }
            defer { automatic.cancel() }
            try await Task.sleep(for: .milliseconds(70))
            automatic.cancel()
            await automatic.value
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "configuration" }.count, paging ? 1 : 2)
            if paging { XCTAssertEqual(reader.loadingColumnID, 0) }
            else { XCTAssertTrue(reader.isLoading) }
            await transport.holdIssueRequests(false)
            try await eventually { !reader.isLoading && reader.loadingColumnID == nil }
            XCTAssertNil(reader.errorMessage)
        }
    }

    @MainActor
    func testCancellingAutomaticRefreshCancelsItsRequestsAndPreservesSnapshot() async throws {
        let transport = BoardFixtureTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
        let previous = reader.snapshot?.fetchedAt
        await transport.holdIssueRequests(true)
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(10)) }
        defer { automatic.cancel() }
        try await eventually { reader.isLoading }
        automatic.cancel()
        await automatic.value
        XCTAssertFalse(reader.isLoading)
        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(reader.snapshot?.fetchedAt, previous)
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1"])
    }

    @MainActor
    func testFailedAutomaticRefreshPreservesCardsAndRetriesOnNextInterval() async throws {
        let transport = BoardFixtureTransport()
        let reader = BoardReader(site: site, account: "alice", cache: try ConnectionCache(path: ":memory:"),
                                 client: JiraClient(transport: transport)) { "token" }
        defer { reader.reset() }
        reader.openProject("10000")
        try await eventually { reader.snapshot != nil && !reader.isLoading && !reader.isLoadingBoards }
        let previous = reader.snapshot?.fetchedAt
        await transport.failDoneColumn()
        let automatic = Task { await reader.refreshAutomatically(every: .milliseconds(30)) }
        defer { automatic.cancel() }
        try await eventually { reader.errorMessage != nil && !reader.isLoading }
        XCTAssertEqual(reader.snapshot?.fetchedAt, previous)
        XCTAssertEqual(reader.snapshot?.issues.map(\.key), ["NEW-1"])
        await transport.failDoneColumn(false)
        try await eventually { reader.snapshot?.fetchedAt != previous && !reader.isLoading }
        automatic.cancel()
        await automatic.value
        XCTAssertNil(reader.errorMessage)
        XCTAssertFalse(reader.isOffline)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @MainActor
    private func seed(_ cache: ConnectionCache, snapshots: [CachedBoard]) async throws {
        for snapshot in snapshots { try await cache.saveBoard(snapshot, site: site.identifier, account: "alice") }
        try await cache.saveBoards(CachedBoards(boards: snapshots.map(\.board), fetchedAt: Date(), responses: []),
                                   site: site.identifier, account: "alice", project: "10000")
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "Timed out waiting for board state")
    }
}

private enum BoardFixture {
    static let iconURL = URL(string: "https://jira.example.com/type.png")!
    static func configuration(id: Int = 1) -> String {
        """
        {"id":\(id),"name":"Team","columnConfig":{"columns":[
        {"name":"In progress","statuses":[{"id":"10"},{"id":"11"}]},
        {"name":"Done","statuses":[{"id":"20"}]}]},
        "subQuery":{"query":"fixVersion in unreleasedVersions() OR fixVersion is EMPTY"}}
        """
    }
    static func issue(_ key: String, status: String = "10", summary: String = "Summary", user: String? = "alice") -> String {
        let assignee = user.map { "{\"name\":\"\($0)\",\"displayName\":\"\($0)\"}" } ?? "null"
        return """
        {"id":"\(key)","key":"\(key)","fields":{"summary":"\(summary)","status":{"id":"\(status)","name":"Same name"},
        "assignee":\(assignee),"issuetype":{"name":"Task","iconUrl":"\(iconURL.absoluteString)"}}}
        """
    }
    static func page(start: Int = 0, total: Int? = nil, issues: [String] = [issue("EX-1")]) -> String {
        "{\"startAt\":\(start),\"maxResults\":1,\"total\":\(total ?? issues.count),\"issues\":[\(issues.joined(separator: ","))]}"
    }
    static func snapshot(id: Int = 1, page json: String = page()) throws -> CachedBoard {
        let config = Data(configuration(id: id).utf8)
        let pageData = Data(json.utf8)
        return CachedBoard(board: JiraBoard(id: id, name: "Team", type: "kanban"),
                           configuration: try JSONDecoder().decode(BoardConfiguration.self, from: config),
                           configurationResponse: config,
                           pages: [CachedIssuePage(page: try JSONDecoder().decode(IssuePage.self, from: pageData), response: pageData, fetchedAt: Date())],
                           isComplete: true, fetchedAt: Date())
    }
}

private actor BoardFixtureTransport: JiraTransport {
    private(set) var requests: [URLRequest] = []
    private var held = Set<Int>()
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var failIssues: Bool
    private var failDone = false
    private var holdIssues = false
    init(failIssues: Bool = false) { self.failIssues = failIssues }
    func holdConfiguration(_ id: Int) { held.insert(id) }
    func releaseConfiguration(_ id: Int) {
        held.remove(id)
        continuations.removeValue(forKey: id)?.resume()
    }
    func failDoneColumn(_ fail: Bool = true) { failDone = fail }
    func holdIssueRequests(_ hold: Bool) { holdIssues = hold }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "board":
            body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Team","type":"kanban"},{"id":2,"name":"Other","type":"kanban"}]}"#
        case "editmodel.json":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "rapidViewId" }!.value!
            body = "{\"swimlanesConfig\":{\"rapidViewId\":\(id),\"swimlaneStrategy\":\"none\",\"swimlanes\":[]}}"
        case "configuration":
            let id = Int(url.deletingLastPathComponent().lastPathComponent)!
            if held.contains(id) { await withCheckedContinuation { continuations[id] = $0 } }
            body = BoardFixture.configuration(id: id)
        case "issue":
            while holdIssues { try await Task.sleep(for: .milliseconds(5)) }
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "startAt" }!.value!
            let done = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "jql" }!.value!.hasPrefix("status in (20)")
            if failIssues || (failDone && done) { throw URLError(.notConnectedToInternet) }
            body = done ? BoardFixture.page(total: 0, issues: [])
                : BoardFixture.page(start: Int(offset)!, total: 2, issues: [BoardFixture.issue(offset == "0" ? "NEW-1" : "NEW-2")])
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor LargeBoardTransport: JiraTransport {
    private(set) var issueRequests: [URLRequest] = []
    private var failNextPage = false
    func setFailNextPage(_ value: Bool) { failNextPage = value }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "board":
            body = #"{"startAt":0,"maxResults":50,"isLast":true,"values":[{"id":1,"name":"Team","type":"kanban"}]}"#
        case "editmodel.json":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "rapidViewId" }!.value!
            body = "{\"swimlanesConfig\":{\"rapidViewId\":\(id),\"swimlaneStrategy\":\"none\",\"swimlanes\":[]}}"
        case "configuration": body = BoardFixture.configuration()
        case "issue":
            issueRequests.append(request)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(items.first { $0.name == "startAt" }!.value!)!
            if failNextPage && offset > 0 { throw URLError(.notConnectedToInternet) }
            let filter = items.first { $0.name == "jql" }!.value!
            let doneOnly = filter.hasPrefix("status in (20)")
            let activeOnly = filter.hasPrefix("status in (10,11)")
            let all = (activeOnly ? [] : (0..<550).map { BoardFixture.issue("DONE-\($0)", status: "20") })
                + (doneOnly ? [] : [BoardFixture.issue("ACTIVE-1", status: "10")])
            let page = Array(all.dropFirst(offset).prefix(50))
            body = "{\"startAt\":\(offset),\"maxResults\":50,\"total\":\(all.count),\"issues\":[\(page.joined(separator: ","))]}"
        default: throw JiraError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
