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
    public private(set) var errorMessage: String?
    public private(set) var listError: String?
    public private(set) var isOffline = false
    public var filterText = "" { didSet { resetVisibleLimits() } }
    public var onlyMyIssues = false { didSet { resetVisibleLimits() } }
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
            lanes = snapshot?.lanes(matching: filterText, assignee: onlyMyIssues ? account : nil, limits: visibleLimits) ?? []
            columns = lanes.flatMap(\.columns)
        } else {
            lanes = []
            columns = snapshot?.columns(matching: filterText, assignee: onlyMyIssues ? account : nil, limits: visibleLimits) ?? []
        }
    }

    public func loadMore(column: Int) {
        guard !isLoading, loadingColumnID == nil, let saved = snapshot,
              let visible = columns.first(where: { $0.id == column }), visible.hasMore else { return }
        let previousLimit = visibleLimits[column] ?? 50
        visibleLimits[column] = previousLimit + 50
        rebuildColumns()
        let revealedCachedCards = (columns.first { $0.id == column }?.issues.count ?? 0) > visible.issues.count
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
        selectedBoardID = id
        snapshot = id.flatMap { recent[$0] }
        filterText = ""
        errorMessage = nil
        isOffline = false
        onPresentation?([:])
        guard let board = selectedBoard else { return }
        beginLoading(board: board, restore: true)
    }

    public func refresh() {
        guard let board = selectedBoard else { refreshBoards(); return }
        beginLoading(board: board, restore: snapshot == nil)
    }

    public func reset() {
        listTask?.cancel()
        listGeneration = UUID()
        listTask = nil
        cancelBoard()
        projectID = nil
        boards = []
        selectedBoardID = nil
        snapshot = nil
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
    }

    private func beginLoading(board: JiraBoard, restore: Bool) {
        cancelBoard()
        let generation = boardGeneration
        let project = projectID
        isLoading = true
        errorMessage = nil
        isOffline = false
        boardTask = Task {
            defer { if boardGeneration == generation { isLoading = false; boardTask = nil } }
            do {
                if restore {
                    let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    if let saved { present(saved.board, images: saved.images) }
                }
                if let project {
                    try await cache.saveBoardSelection(board.id, site: site.identifier, account: account, project: project)
                }
                let credential = try await credentials()
                let (serverConfiguration, response) = try await client.boardConfiguration(site: site, token: credential, boardID: board.id)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                try await cache.saveBoardResponse(response, site: site.identifier, account: account, boardID: board.id, resource: "configuration")
                let swimlanes = try await client.boardSwimlanes(site: site, token: credential, boardID: board.id)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                try await cache.saveBoardResponse(swimlanes.response, site: site.identifier, account: account,
                                                  boardID: board.id, resource: "swimlanes")
                let configuration = serverConfiguration.excludingKanbanBacklog(board.type == "kanban" && swimlanes.kanbanBacklogEnabled)
                var result = CachedBoard(board: board, configuration: configuration, configurationResponse: response,
                                         pages: [], isComplete: false, fetchedAt: Date())
                result.columnPages = [:]
                result.retainedIssues = snapshot?.completedIssuesCutoff == swimlanes.completedIssuesCutoff ? snapshot?.issues : nil
                result.swimlanesResponse = swimlanes.response
                result.completedIssuesCutoff = swimlanes.completedIssuesCutoff
                if !swimlanes.lanes.isEmpty {
                    result.retainedIssues = nil
                    result.laneSnapshots = swimlanes.lanes.map { lane in
                        var child = CachedBoard(board: board, configuration: configuration, configurationResponse: response,
                                                pages: [], isComplete: false, fetchedAt: Date())
                        child.columnPages = [:]
                        child.completedIssuesCutoff = swimlanes.completedIssuesCutoff
                        if snapshot?.completedIssuesCutoff == swimlanes.completedIssuesCutoff,
                           let previous = snapshot?.laneSnapshots?.first(where: { $0.lane == lane }) {
                            child.retainedIssues = previous.board.issues
                        }
                        return CachedBoardLane(lane: lane, board: child)
                    }
                }
                // Fetch one page per column and swimlane. Preserve the previous snapshot until every first page succeeds.
                let keepPrevious = snapshot != nil
                let columnCount = configuration.columnConfig.columns.count
                let cellCount = columnCount * max(1, swimlanes.lanes.count)
                var verified = Set<String>()
                for index in 0..<cellCount {
                    let scope = result.requestScope(column: index)
                    if configuration.columnConfig.columns[scope.column].statuses.isEmpty { continue }
                    let page = try await client.boardIssues(site: site, token: credential, board: board,
                                                           configuration: configuration, startAt: 0, column: scope.column,
                                                           swimlaneFilter: scope.filter, completedIssuesCutoff: result.completedIssuesCutoff)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    try await reconcile(page, configuration: configuration, column: scope.column,
                                        credential: credential, verified: &verified)
                    try Task.checkCancellation()
                    guard boardGeneration == generation else { return }
                    try result.append(page, column: index)
                    try await cache.saveBoardResponse(page.response, site: site.identifier, account: account,
                                                      boardID: board.id, resource: "column:\(index):0")
                    if !keepPrevious {
                        try await cache.saveBoard(result, site: site.identifier, account: account)
                        let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                        try Task.checkCancellation()
                        guard boardGeneration == generation else { return }
                        if let saved { present(saved.board, images: saved.images) }
                    }
                }
                result.isComplete = (0..<cellCount).allSatisfy { !result.hasNextPage(column: $0) }
                try await cache.saveBoard(result, site: site.identifier, account: account)
                let saved = try await cache.loadBoardPresentation(site: site.identifier, account: account, boardID: board.id)
                try Task.checkCancellation()
                guard boardGeneration == generation else { return }
                if let saved { present(saved.board, images: saved.images) }
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
            rebuildColumns()
        }
    }

    private func reconcile(_ page: CachedIssuePage, configuration: BoardConfiguration, column: Int,
                           credential: String, verified: inout Set<String>) async throws {
        let merged = try await cache.reconcileIssues(page.page.issues, site: site.identifier, account: account)
        let statuses = Set(configuration.columnConfig.columns[column].statuses.map(\.id))
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
