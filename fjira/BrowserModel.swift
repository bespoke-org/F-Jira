import AppKit
import FjiraCore
import Foundation
import Observation

@MainActor
@Observable
final class BrowserModel {
    let connection: CachedConnection
    let issueReader: IssueReader
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
    private(set) var accountAvatar: CachedAvatar?
    private(set) var projectAvatars: [URL: CachedAvatar] = [:]
    private(set) var tableImages: [String: NSImage] = [:]

    @ObservationIgnored private var tableImageTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedTableImages = Set<URL>()
    @ObservationIgnored private var tableImageDates: [String: Date] = [:]

    @ObservationIgnored private let cache: ConnectionCache
    @ObservationIgnored private let client: JiraClient
    @ObservationIgnored private let tokenStore = TokenStore()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var projectTask: Task<Void, Never>?
    @ObservationIgnored private var accountAvatarTask: Task<Void, Never>?
    @ObservationIgnored private var projectAvatarTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var selectionID = UUID()

    init(connection: CachedConnection, cache: ConnectionCache, client: JiraClient = JiraClient()) {
        self.connection = connection
        self.cache = cache
        self.client = client
        issueReader = IssueReader(site: connection.site, account: connection.user.identifier, cache: cache, client: client) {
            guard let token = try TokenStore().load(site: connection.site.identifier, account: connection.user.identifier) else {
                throw JiraError.missingToken
            }
            return token
        }
    }

    var selectedProject: JiraProject? { projects.first { $0.id == selectedProjectID } }
    private var site: String { connection.site.identifier }
    private var account: String { connection.user.identifier }

    func restore() async {
        guard isRestoring else { return }
        loadAccountAvatar()
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
        issueReader.close()
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
        issueReader.close()
        cancelSearch()
        projectTask?.cancel()
        accountAvatarTask?.cancel()
        for task in projectAvatarTasks.values { task.cancel() }
        tableImageTask?.cancel()
        selectionTask?.cancel()
        selectionID = UUID()
    }

    func loadProjectAvatar(_ project: JiraProject) {
        guard let url = project.avatarURL, projectAvatarTasks[url] == nil else { return }
        if let saved = projectAvatars[url], Date().timeIntervalSince(saved.fetchedAt) < 86_400 { return }
        projectAvatarTasks[url] = Task {
            defer { projectAvatarTasks[url] = nil }
            do {
                if let saved = try await cache.loadAvatar(site: site, account: account, url: url) {
                    try Task.checkCancellation()
                    projectAvatars[url] = saved
                    if Date().timeIntervalSince(saved.fetchedAt) < 86_400 { return }
                }
                let avatar = try await client.avatar(site: connection.site, token: credentials(), url: url)
                try Task.checkCancellation()
                try await cache.saveAvatar(avatar, site: site, account: account, url: url)
                try Task.checkCancellation()
                projectAvatars[url] = avatar
            } catch {
                // Keep the cached project image when Jira is unavailable.
            }
        }
    }

    private func loadAccountAvatar() {
        guard let url = connection.profileUser.avatarURL else { return }
        accountAvatarTask?.cancel()
        accountAvatarTask = Task {
            do {
                if let saved = try await cache.loadAvatar(site: site, account: account, url: url) {
                    try Task.checkCancellation()
                    accountAvatar = saved
                    if Date().timeIntervalSince(saved.fetchedAt) < 86_400 { return }
                }
                let avatar = try await client.avatar(site: connection.site, token: credentials(), url: url)
                try Task.checkCancellation()
                try await cache.saveAvatar(avatar, site: site, account: account, url: url)
                try Task.checkCancellation()
                accountAvatar = try await cache.loadAvatar(site: site, account: account, url: url)
            } catch {
                // Preserve the cached image or account icon when the image cannot be refreshed.
            }
        }
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
                    let saved = try await cache.loadSearchPresentation(site: site, account: account, query: query)
                    try Task.checkCancellation()
                    guard requestID == generation else { return }
                    presentSearch(saved)
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
                let saved = try await cache.loadSearchPresentation(site: site, account: account, query: query)
                let recent = try await cache.recentSearches(site: site, account: account, project: query.projectID)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                presentSearch(saved)
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
        let saved = try await cache.loadSearchPresentation(site: site, account: account, query: query)
        try Task.checkCancellation()
        guard generation == nil || selectionID == generation else { return }
        history = recent
        queryText = text
        presentSearch(saved)
        try await cache.saveSelection(site: site, account: account, project: id, input: text)
    }

    private func presentSearch(_ presentation: (search: CachedSearch, images: [String: CachedAvatar])?) {
        applyTableImages(presentation?.images ?? [:])
        search = presentation?.search
        attemptedTableImages = []
        // Start type/priority icons first, and limit concurrent image requests for large assignee lists.
        if tableImageTask == nil {
            tableImageTask = Task {
                defer { tableImageTask = nil }
                var credential: String?
                while !Task.isCancelled {
                    let missing = (search?.tableImageURLs ?? []).filter { url in
                        tableImageDates[url.absoluteString].map { Date().timeIntervalSince($0) >= 86_400 } ?? true
                    }
                    let pending = missing.filter { !attemptedTableImages.contains($0) }
                    guard !pending.isEmpty else { return }
                    let batch = Array(pending.prefix(4))
                    attemptedTableImages.formUnion(batch)
                    if credential == nil { credential = try? await credentials() }
                    guard let token = credential, !Task.isCancelled else { return }
                    let images = await withTaskGroup(of: (String, CachedAvatar?).self, returning: [String: CachedAvatar].self) { group in
                        for url in batch {
                            group.addTask { [client, cache, connection] in
                                do {
                                    let image = try await client.avatar(site: connection.site, token: token, url: url)
                                    try Task.checkCancellation()
                                    try await cache.saveAvatar(image, site: connection.site.identifier,
                                                               account: connection.user.identifier, url: url)
                                    return (url.absoluteString, image)
                                } catch { return (url.absoluteString, nil) }
                            }
                        }
                        var result: [String: CachedAvatar] = [:]
                        for await (url, image) in group {
                            if let image { result[url] = image }
                        }
                        return result
                    }
                    guard !Task.isCancelled else { return }
                    applyTableImages(images)
                }
            }
        }
    }

    private func applyTableImages(_ images: [String: CachedAvatar]) {
        issueReader.reuseImages(images)
        for (url, cached) in images {
            if let date = tableImageDates[url], date >= cached.fetchedAt { continue }
            if let image = NSImage(data: cached.data) {
                tableImages[url] = image
                tableImageDates[url] = cached.fetchedAt
            }
        }
    }

    private func apply(_ saved: CachedProjects) {
        projects = saved.projects.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        projectsFetchedAt = saved.fetchedAt
    }

    private func credentials() async throws -> String {
        let credential = try await Task.detached { [tokenStore, site, account] in
            guard let token = try tokenStore.load(site: site, account: account) else { throw JiraError.missingToken }
            return token
        }.value
        try Task.checkCancellation()
        return credential
    }

    private func message(for error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .timedOut { return "Jira did not respond in time. Downloaded data remains available." }
            return "Cannot reach Jira. Check your connection and VPN. Downloaded data remains available."
        }
        return error.localizedDescription
    }
}
