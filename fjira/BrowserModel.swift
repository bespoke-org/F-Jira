import FjiraCore
import Foundation
import Observation

@MainActor
@Observable
final class BrowserModel {
    let connection: CachedConnection
    var queryText = ""
    private(set) var projects: [JiraProject] = []
    private(set) var projectsFetchedAt: Date?
    private(set) var selectedProjectID: String?
    private(set) var search: CachedSearch?
    private(set) var history: [CachedSearch] = []
    private(set) var isRestoring = true
    private(set) var isLoadingProjects = false
    private(set) var isLoadingCache = false
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var projectError: String?

    @ObservationIgnored private let cache: ConnectionCache
    @ObservationIgnored private let client: JiraClient
    @ObservationIgnored private let tokenStore = TokenStore()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var projectTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var selectionID = UUID()

    init(connection: CachedConnection, cache: ConnectionCache, client: JiraClient = JiraClient()) {
        self.connection = connection
        self.cache = cache
        self.client = client
    }

    var selectedProject: JiraProject? { projects.first { $0.id == selectedProjectID } }
    private var site: String { connection.site.identifier }
    private var account: String { connection.user.identifier }

    func restore() async {
        guard isRestoring else { return }
        do {
            if let saved = try await cache.loadProjects(site: site, account: account) { apply(saved) }
            let selection = try await cache.loadSelection(site: site, account: account)
            let project = projects.first { $0.id == selection?.project } ?? projects.first
            selectedProjectID = project?.id
            if let project {
                try await loadProject(project.id, input: selection?.project == project.id ? selection?.input : nil)
            }
        } catch { projectError = message(for: error) }
        isRestoring = false
        refreshProjects()
    }

    func refreshProjects() {
        guard !isLoadingProjects else { return }
        isLoadingProjects = true
        projectError = nil
        projectTask = Task {
            defer { isLoadingProjects = false; projectTask = nil }
            do {
                let result = try await client.projects(site: connection.site, token: credentials())
                try Task.checkCancellation()
                try await cache.saveProjects(result, site: site, account: account)
                guard let saved = try await cache.loadProjects(site: site, account: account) else { return }
                apply(saved)
                if !projects.contains(where: { $0.id == selectedProjectID }) {
                    selectProject(projects.first?.id)
                }
            } catch is CancellationError { }
            catch { projectError = message(for: error) }
        }
    }

    func selectProject(_ id: String?, cachedInput: String? = nil, searchIfMissing: Bool = true) {
        cancelSearch()
        selectionTask?.cancel()
        selectionID = UUID()
        let generation = selectionID
        selectedProjectID = id
        search = nil
        history = []
        queryText = ""
        errorMessage = nil
        guard let id else { isLoadingCache = false; return }
        isLoadingCache = true
        selectionTask = Task {
            defer { if selectionID == generation { isLoadingCache = false; selectionTask = nil } }
            do {
                try await loadProject(id, input: cachedInput, generation: generation)
                guard selectionID == generation, !Task.isCancelled else { return }
                isLoadingCache = false
                if search == nil && searchIfMissing { runSearch() }
            } catch is CancellationError { }
            catch { if selectionID == generation { errorMessage = message(for: error) } }
        }
    }

    func openCachedSearch(_ input: String) {
        selectProject(selectedProjectID, cachedInput: input, searchIfMissing: false)
    }

    func runSearch() {
        guard let selectedProjectID, !isLoadingCache else { return }
        do {
            let query = try ProjectQuery(projectID: selectedProjectID, input: queryText)
            startSearch(query: query, append: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() {
        guard let search, search.hasMore, !isSearching, !isLoadingCache else { return }
        startSearch(query: search.query, append: true)
    }

    func cancelSearch() {
        searchTask?.cancel()
        requestID = UUID()
        isSearching = false
        searchTask = nil
    }

    func stop() {
        cancelSearch()
        projectTask?.cancel()
        selectionTask?.cancel()
        selectionID = UUID()
    }

    private func startSearch(query: ProjectQuery, append: Bool) {
        cancelSearch()
        let generation = requestID
        let prior = search
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            defer { if requestID == generation { isSearching = false; searchTask = nil } }
            do {
                if !append {
                    let saved = try await cache.loadSearch(site: site, account: account, query: query)
                    try Task.checkCancellation()
                    guard requestID == generation else { return }
                    search = saved
                }
                let page = try await client.search(
                    site: connection.site, token: credentials(), query: query,
                    startAt: append ? prior?.nextStartAt ?? 0 : 0
                )
                try Task.checkCancellation()
                guard requestID == generation else { return }
                try await cache.savePage(
                    page, site: site, account: account, query: query,
                    expectedGeneration: append ? prior?.generation : nil
                )
                let saved = try await cache.loadSearch(site: site, account: account, query: query)
                let recent = try await cache.recentSearches(site: site, account: account, project: query.projectID)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                search = saved
                history = recent
                try await cache.saveSelection(site: site, account: account, project: query.projectID, input: query.input)
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { if requestID == generation { errorMessage = message(for: error) } }
        }
    }

    private func loadProject(_ id: String, input: String?, generation: UUID? = nil) async throws {
        let recent = try await cache.recentSearches(site: site, account: account, project: id)
        let text = input ?? recent.first?.query.input ?? ""
        let query = try ProjectQuery(projectID: id, input: text)
        let saved = try await cache.loadSearch(site: site, account: account, query: query)
        try Task.checkCancellation()
        guard generation == nil || selectionID == generation else { return }
        history = recent
        queryText = text
        search = saved
        try await cache.saveSelection(site: site, account: account, project: id, input: text)
    }

    private func apply(_ saved: CachedProjects) {
        projects = saved.projects.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        projectsFetchedAt = saved.fetchedAt
    }

    private func credentials() throws -> String {
        guard let token = try tokenStore.load(site: site, account: account) else { throw JiraError.missingToken }
        return token
    }

    private func message(for error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .timedOut { return "Jira did not respond in time. Downloaded data remains available." }
            return "Cannot reach Jira. Check your connection and VPN. Downloaded data remains available."
        }
        return error.localizedDescription
    }
}
