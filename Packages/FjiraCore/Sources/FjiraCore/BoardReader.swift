import Foundation
import Observation

@MainActor
@Observable
public final class BoardReader {
    public private(set) var projectID: String?
    public private(set) var boards: [JiraBoard] = []
    public private(set) var selectedBoardID: Int?
    public private(set) var snapshot: CachedBoard?
    public private(set) var isLoadingBoards = false
    public private(set) var isLoading = false
    public private(set) var isRefreshingAutomatically = false
    public private(set) var errorMessage: String?
    public private(set) var listError: String?
    public private(set) var isOffline = false
    public var filterText = "" { didSet { resetVisibleLimits() } }
    public var selectedAssigneeID: String? {
        didSet {
            if oldValue != selectedAssigneeID {
                rebuildAssignees()
                resetVisibleLimits()
            }
        }
    }
    public private(set) var assignees: [JiraUser] = []
    public var currentUserID: String { account }
    public private(set) var columns: [BoardColumn] = []
    public private(set) var lanes: [BoardLane] = []
    public private(set) var loadingColumnID: Int?
    public private(set) var columnErrors: [Int: String] = [:]
    @ObservationIgnored private var visibleLimits: [Int: Int] = [:]
    @ObservationIgnored private var pagingTask: Task<Void, Never>?
    @ObservationIgnored public var onIssuesUpdate: (([JiraIssue]) -> Void)?
    @ObservationIgnored public var onPresentation: (([String: CachedAvatar]) -> Void)?

    @ObservationIgnored private let site: JiraSite
    @ObservationIgnored private let account: String
    @ObservationIgnored private let cache: ConnectionCache
    @ObservationIgnored private let client: JiraClient
    @ObservationIgnored private let token: @Sendable () throws -> String
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var boardTask: Task<Void, Never>?
    @ObservationIgnored private var listGeneration = UUID()
    @ObservationIgnored private var boardGeneration = UUID()
    @ObservationIgnored private var recent: [Int: CachedBoard] = [:]
    @ObservationIgnored private var recentOrder: [Int] = []
    @ObservationIgnored private var metadata: (boardID: Int, configuration: BoardConfiguration, response: Data,
                                               swimlanes: BoardSwimlaneSettings, fetchedAt: ContinuousClock.Instant)?
    @ObservationIgnored private var lastContents: Data?
    @ObservationIgnored private var changeToken: String?
    @ObservationIgnored private var changeChecksAvailable = true
    @ObservationIgnored private var lastFullRefresh: ContinuousClock.Instant?

    public init(site: JiraSite, account: String, cache: ConnectionCache, client: JiraClient = JiraClient(),
                token: @escaping @Sendable () throws -> String) {
        self.site = site
        self.account = account
        self.cache = cache
        self.client = client
        self.token = token
    }

    public var selectedBoard: JiraBoard? { boards.first { $0.id == selectedBoardID } }
    public var imageURLs: [URL] {
        var seen = Set<URL>()
        let issues = columns.flatMap(\.issues)
        return (issues.compactMap { $0.fields.issuetype?.iconUrl }
            + issues.compactMap { $0.fields.priority?.iconUrl }
            + issues.compactMap { $0.fields.assignee?.avatarURL }).filter { seen.insert($0).inserted }
    }

    private func resetVisibleLimits() {
        visibleLimits = [:]
        rebuildColumns()
        onPresentation?([:])
    }

    private func rebuildColumns() {
        if snapshot?.laneSnapshots != nil {
            lanes = snapshot?.lanes(matching: filterText, assignee: selectedAssigneeID, limits: visibleLimits) ?? []
            columns = lanes.flatMap(\.columns)
        } else {
            lanes = []
            columns = snapshot?.columns(matching: filterText, assignee: selectedAssigneeID, limits: visibleLimits) ?? []
        }
    }

    private func rebuildAssignees() {
        let selected = assignees.first { $0.identifier == selectedAssigneeID }
        var users: [String: JiraUser] = [:]
        // Ignore current text/person filters and display limits, but respect board membership.
        for issue in snapshot?.columns().flatMap(\.issues) ?? [] {
            if let user = issue.fields.assignee { users[user.identifier] = user }
        }
        // Keep the active choice named if a refresh leaves that person with no matching cards.
        if let selected, users[selected.identifier] == nil { users[selected.identifier] = selected }
        assignees = users.values.sorted {
            if ($0.identifier == account) != ($1.identifier == account) { return $0.identifier == account }
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    public func loadMore(column: Int) {
        guard !isLoading, loadingColumnID == nil, let saved = snapshot,
              let visible = columns.first(where: { $0.id == column }), visible.hasMore else { return }
        let previousLimit = visibleLimits[column] ?? 50
        visibleLimits[column] = previousLimit + 50
        rebuildColumns()
        let revealedCachedCards = (columns.first { $0.id == column }?.issues.count ?? 0) > visible.issues.count
        // Upgrade incomplete legacy lane caches through positive membership queries.
        if saved.laneSnapshots != nil, saved.hasNextPage(column: column), !isOffline {
            beginLoading(board: saved.board, restore: false)
            return
        }
        columnErrors[column] = nil
        loadingColumnID = column
        let generation = boardGeneration
        pagingTask = Task {
            defer { if boardGeneration == generation { loadingColumnID = nil; pagingTask = nil } }
            do {
                let images = try await cache.loadBoardImages(site: site.identifier, account: account, urls: imageURLs)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                onPresentation?(images)
                // Previously downloaded pages can be revealed without waiting for connectivity.
                if !saved.hasNextPage(column: column) || (isOffline && revealedCachedCards) { return }
                // Legacy snapshots have board-wide offsets. Restart only this column at offset zero.
                let offset = saved.nextStartAt(column: column)
                let scope = saved.requestScope(column: column)
                let credential = try await credentials()
                let page = try await client.boardIssues(site: site, token: credential, board: saved.board,
                                                       configuration: saved.configuration, startAt: offset, column: scope.column,
                                                       swimlaneFilter: scope.filter, completedIssuesCutoff: saved.completedIssuesCutoff)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                var verified = Set<String>()
                try await reconcile(page, configuration: saved.configuration, column: scope.column,
                                    credential: credential, verified: &verified)
                try Task.checkCancellation()
                guard boardGeneration == generation, var result = snapshot else { return }
                if result.columnPages == nil {
                    result.retainedIssues = result.issues
                    result.pages = []
                    result.columnPages = [:]
                }
                try result.append(page, column: column)
                try await cache.saveBoard(result, site: site.identifier, account: account)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                if let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: result.board.id) {
                    result = saved.board
                }
                let newImages = try await cache.loadBoardImages(site: site.identifier, account: account,
                    urls: result.imageURLs(limits: visibleLimits))
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                present(result, images: newImages)
                isOffline = false
                errorMessage = nil
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch {
                guard boardGeneration == generation else { return }
                if !revealedCachedCards { visibleLimits[column] = previousLimit; rebuildColumns() }
                record(error)
                columnErrors[column] = message(for: error)
            }
        }
    }

    public func openProject(_ id: String?) {
        guard id != projectID else { return }
        reset()
        projectID = id
        guard id != nil else { return }
        refreshBoards()
    }

    public func refreshBoards() {
        guard let projectID else { return }
        listTask?.cancel()
        listGeneration = UUID()
        let generation = listGeneration
        isLoadingBoards = true
        listError = nil
        listTask = Task {
            defer { if listGeneration == generation { isLoadingBoards = false; listTask = nil } }
            do {
                if boards.isEmpty {
                    let saved = try await cache.loadBoards(site: site.identifier, account: account, project: projectID)
                    let selection = try await cache.loadBoardSelection(site: site.identifier, account: account, project: projectID)
                    try Task.checkCancellation()
                    guard listGeneration == generation else { return }
                    boards = saved?.boards ?? []
                    if !boards.isEmpty { selectBoard(boards.first { $0.id == selection }?.id ?? boards.first?.id) }
                }
                let result = try await client.boards(site: site, token: credentials(), projectID: projectID)
                try Task.checkCancellation()
                guard listGeneration == generation else { return }
                try await cache.saveBoards(result, site: site.identifier, account: account, project: projectID)
                try Task.checkCancellation()
                guard listGeneration == generation else { return }
                boards = result.boards
                if !boards.contains(where: { $0.id == selectedBoardID }) { selectBoard(boards.first?.id) }
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { if listGeneration == generation { listError = message(for: error) } }
        }
    }

    public func selectBoard(_ id: Int?) {
        guard id != selectedBoardID else { return }
        cancelBoard()
        metadata = nil
        lastContents = nil
        changeToken = nil
        changeChecksAvailable = true
        lastFullRefresh = nil
        selectedBoardID = id
        snapshot = id.flatMap { recent[$0] }
        selectedAssigneeID = nil
        rebuildAssignees()
        filterText = ""
        errorMessage = nil
        isOffline = false
        onPresentation?([:])
        guard let board = selectedBoard else { return }
        beginLoading(board: board, restore: true)
    }

    public func refresh() {
        refreshBoards()
        guard let board = selectedBoard else { return }
        beginLoading(board: board, restore: snapshot == nil)
    }

    /// The visible board owns this task. Cancellation stops only the refresh started by this loop.
    public func refreshAutomatically(every interval: Duration = .seconds(5), fullRefreshEvery: Duration = .seconds(60)) async {
        guard interval > .zero, fullRefreshEvery > .zero else { return }
        var delay = interval
        var failures = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            delay = interval
            guard !isLoading, loadingColumnID == nil,
                  let board = selectedBoard else { continue }
            let started = ContinuousClock.now
            beginLoading(board: board, restore: snapshot == nil, automatic: true, maximumAge: fullRefreshEvery)
            guard let task = boardTask else { continue }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if errorMessage != nil {
                failures = min(failures + 1, 4)
                delay = min(.seconds(60), interval * (1 << failures))
            } else {
                failures = 0
                // Aim for a five-second cadence; slow refreshes still get a breathing gap.
                delay = max(min(interval, .seconds(1)), interval - started.duration(to: .now))
            }
        }
    }

    public func reset() {
        listTask?.cancel()
        listGeneration = UUID()
        listTask = nil
        cancelBoard()
        metadata = nil
        lastContents = nil
        changeToken = nil
        changeChecksAvailable = true
        lastFullRefresh = nil
        projectID = nil
        boards = []
        selectedBoardID = nil
        snapshot = nil
        selectedAssigneeID = nil
        assignees = []
        columns = []
        lanes = []
        isLoadingBoards = false
        listError = nil
        errorMessage = nil
        isOffline = false
        filterText = ""
    }

    private func cancelBoard() {
        pagingTask?.cancel()
        pagingTask = nil
        loadingColumnID = nil
        columnErrors = [:]
        boardTask?.cancel()
        boardGeneration = UUID()
        boardTask = nil
        isLoading = false
        isRefreshingAutomatically = false
    }

    private func beginLoading(board: JiraBoard, restore: Bool, automatic: Bool = false, maximumAge: Duration = .seconds(60)) {
        cancelBoard()
        let generation = boardGeneration
        let project = projectID
        isLoading = true
        isRefreshingAutomatically = automatic
        if !automatic { errorMessage = nil; isOffline = false }
        boardTask = Task {
            defer { if boardGeneration == generation { isLoading = false; isRefreshingAutomatically = false; boardTask = nil } }
            do {
                if restore {
                    let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    if let saved { present(saved.board, images: saved.images) }
                }
                if !automatic, let project {
                    try await cache.saveBoardSelection(board.id, site: site.identifier, account: account, project: project)
                }
                let credential = try await credentials()
                let fullRefreshDue = lastFullRefresh.map { $0.duration(to: .now) >= maximumAge } ?? true
                var candidateToken: BoardChangeToken?
                if changeChecksAvailable {
                    do {
                        candidateToken = try await client.boardChangeToken(site: site, token: credential,
                                                                          boardID: board.id, previous: changeToken)
                    } catch {
                        try Task.checkCancellation()
                        guard boardGeneration == generation else { return }
                        switch error {
                        case JiraError.notFound, JiraError.forbidden, JiraError.invalidResponse,
                             JiraError.queryRejected, JiraError.redirected:
                            // Private endpoint absent on this deployment: keep polling the public API.
                            changeChecksAvailable = false
                        default:
                            if automatic { throw error }
                        }
                    }
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    if automatic, !fullRefreshDue, snapshot != nil, candidateToken?.unchanged == true {
                        errorMessage = nil
                        isOffline = false
                        return
                    }
                }
                let metadataExpired = metadata.map { $0.boardID != board.id || $0.fetchedAt.duration(to: .now) >= maximumAge } ?? true
                if !automatic || metadataExpired {
                    async let configRequest = client.boardConfiguration(site: site, token: credential, boardID: board.id)
                    async let laneRequest = client.boardSwimlanes(site: site, token: credential, boardID: board.id)
                    let ((configuration, response), swimlanes) = try await (configRequest, laneRequest)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    metadata = (board.id, configuration, response, swimlanes, .now)
                }
                guard let metadata else { throw JiraError.invalidResponse }
                let (serverConfiguration, response, swimlanes) = (metadata.configuration, metadata.response, metadata.swimlanes)
                let configuration = serverConfiguration.excludingKanbanBacklog(board.type == "kanban" && swimlanes.kanbanBacklogEnabled)
                if !swimlanes.lanes.isEmpty {
                    let result = try await client.boardContents(site: site, token: credential, board: board,
                        configuration: configuration, configurationResponse: response, settings: swimlanes)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    let signature = try result.contentsSignature()
                    if automatic, snapshot != nil, lastContents == signature {
                        changeToken = candidateToken?.value
                        lastFullRefresh = .now
                        errorMessage = nil
                        isOffline = false
                        return
                    }
                    var verified = Set<String>()
                    // Only full card records participate in revision reconciliation, never membership responses.
                    let issues = result.issues
                    let page = CachedIssuePage(page: IssuePage(startAt: 0, maxResults: max(1, issues.count), total: issues.count,
                        issues: issues, warningMessages: nil), response: Data(), fetchedAt: result.fetchedAt)
                    try await reconcile(page, configuration: configuration, column: nil, credential: credential, verified: &verified)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    try await cache.saveBoard(result, site: site.identifier, account: account)
                    let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    if let saved { present(saved.board, images: saved.images) }
                    lastContents = signature
                    changeToken = candidateToken?.value
                    lastFullRefresh = .now
                    errorMessage = nil
                    isOffline = false
                    return
                }
                var result = CachedBoard(board: board, configuration: configuration, configurationResponse: response,
                                         pages: [], isComplete: false, fetchedAt: Date())
                result.columnPages = [:]
                result.retainedIssues = snapshot?.completedIssuesCutoff == swimlanes.completedIssuesCutoff ? snapshot?.issues : nil
                result.swimlanesResponse = swimlanes.response
                result.completedIssuesCutoff = swimlanes.completedIssuesCutoff
                // Ungrouped boards retain per-column paging so large Done columns load on demand.
                let keepPrevious = snapshot != nil
                let columnCount = configuration.columnConfig.columns.count
                let cellCount = columnCount
                let requests = (0..<cellCount).compactMap { index -> (index: Int, column: Int, filter: String?)? in
                    let scope = result.requestScope(column: index)
                    guard !configuration.columnConfig.columns[scope.column].statuses.isEmpty else { return nil }
                    return (index, scope.column, scope.filter)
                }
                let completedIssuesCutoff = result.completedIssuesCutoff
                var verified = Set<String>()
                for start in stride(from: 0, to: requests.count, by: JiraClient.boardRequestLimit) {
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    let batch = Array(requests[start..<min(start + JiraClient.boardRequestLimit, requests.count)])
                    let pages = await withTaskGroup(of: (Int, Result<CachedIssuePage, Error>).self) { group in
                        for request in batch {
                            group.addTask { [client, site] in
                                do {
                                    try Task.checkCancellation()
                                    let page = try await client.boardIssues(site: site, token: credential, board: board,
                                        configuration: configuration, startAt: 0, column: request.column,
                                        swimlaneFilter: request.filter, completedIssuesCutoff: completedIssuesCutoff)
                                    return (request.index, .success(page))
                                } catch { return (request.index, .failure(error)) }
                            }
                        }
                        var pages: [Int: Result<CachedIssuePage, Error>] = [:]
                        for await (index, page) in group { pages[index] = page }
                        return pages
                    }
                    // Apply in board order so reconciliation and partial first downloads remain deterministic,
                    // including when a later column fails before an earlier request finishes.
                    for request in batch {
                        try Task.checkCancellation()
                        guard boardGeneration == generation else { return }
                        guard let response = pages[request.index] else { throw JiraError.invalidResponse }
                        let page = try response.get()
                        try await reconcile(page, configuration: configuration, column: request.column,
                                            credential: credential, verified: &verified)
                        try Task.checkCancellation()
                        guard boardGeneration == generation else { return }
                        try result.append(page, column: request.index)
                        try await cache.saveBoardResponse(page.response, site: site.identifier, account: account,
                                                          boardID: board.id, resource: "column:\(request.index):0")
                        if !keepPrevious {
                            try await cache.saveBoard(result, site: site.identifier, account: account)
                            let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                            try Task.checkCancellation()
                            guard boardGeneration == generation else { return }
                            if let saved { present(saved.board, images: saved.images) }
                        }
                    }
                }
                result.isComplete = (0..<cellCount).allSatisfy { !result.hasNextPage(column: $0) }
                try await cache.saveBoard(result, site: site.identifier, account: account)
                let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                if let saved { present(saved.board, images: saved.images) }
                changeToken = candidateToken?.value
                lastFullRefresh = .now
                errorMessage = nil
                isOffline = false
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch {
                guard boardGeneration == generation else { return }
                record(error)
            }
        }
    }

    private func present(_ board: CachedBoard, images: [String: CachedAvatar] = [:]) {
        let board = board.reconciling(recent[board.board.id]?.issues ?? [], preferOnEqual: false)
        snapshot = board
        rebuildAssignees()
        rebuildColumns()
        recent[board.board.id] = board
        recentOrder.removeAll { $0 == board.board.id }
        recentOrder.append(board.board.id)
        while recentOrder.count > 10 { recent.removeValue(forKey: recentOrder.removeFirst()) }
        onPresentation?(images)
        onIssuesUpdate?(board.issues)
    }

    /// Reconcile visible and recently opened boards without resetting scroll or pagination.
    public func applyKnownIssues(_ issues: [JiraIssue]) {
        for id in recent.keys { recent[id] = recent[id]?.reconciling(issues) }
        if let snapshot {
            self.snapshot = snapshot.reconciling(issues)
            rebuildAssignees()
            rebuildColumns()
        }
    }

    private func reconcile(_ page: CachedIssuePage, configuration: BoardConfiguration, column: Int?,
                           credential: String, verified: inout Set<String>) async throws {
        let merged = try await cache.reconcileIssues(page.page.issues, site: site.identifier, account: account)
        let statuses = Set((column.map { configuration.columnConfig.columns[$0].statuses }
                            ?? configuration.columnConfig.columns.flatMap(\.statuses)).map(\.id))
        let misplaced = page.page.issues.filter { issue in
            issue.fields.status?.id.map { !statuses.contains($0) } ?? false
        }
        let conflicts = (merged.conflicts + misplaced).filter { verified.insert($0.id).inserted }
        // Bound both concurrency and retries: at most one direct lookup per conflicting issue per refresh.
        for start in stride(from: 0, to: conflicts.count, by: 4) {
            let batch = Array(conflicts[start..<min(start + 4, conflicts.count)])
            let confirmed = await withTaskGroup(of: JiraIssue?.self, returning: [JiraIssue].self) { group in
                for issue in batch {
                    group.addTask { [client, site] in
                        try? await client.issueSummary(site: site, token: credential, id: issue.id)
                    }
                }
                var results: [JiraIssue] = []
                for await issue in group { if let issue { results.append(issue) } }
                return results
            }
            try Task.checkCancellation()
            _ = try await cache.reconcileIssues(confirmed, site: site.identifier, account: account, verified: true)
        }
    }

    private func record(_ error: Error) {
        if let urlError = error as? URLError {
            isOffline = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                         .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(urlError.code)
        }
        errorMessage = message(for: error)
    }

    private func credentials() async throws -> String {
        let credential = try await Task.detached { [token] in try token() }.value
        try Task.checkCancellation()
        return credential
    }

    private func message(for error: Error) -> String {
        if error is URLError { return "Cannot reach Jira. Check your connection and VPN. Downloaded boards remain available." }
        if let error = error as? JiraError, error == .notFound {
            return "This board is unavailable. Check your access and that Jira Software is enabled on this server."
        }
        return error.localizedDescription
    }
}
