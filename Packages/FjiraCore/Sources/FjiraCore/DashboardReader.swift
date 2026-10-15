import Foundation
import Observation

@MainActor
@Observable
public final class DashboardReader {
    public private(set) var completion: CachedDashboardCompletion?
    public private(set) var completionError: String?
    public private(set) var isLoadingCompletion = false
    public private(set) var projectID: String?
    public private(set) var sections: [DashboardSection: CachedSearch] = [:]
    public private(set) var sectionErrors: [DashboardSection: String] = [:]
    public private(set) var loadingSections = Set<DashboardSection>()
    public private(set) var recent: [ViewedIssue] = []
    public private(set) var commentScope: DashboardCommentScope = .mine
    public private(set) var comments: CachedDashboardComments?
    public private(set) var commentsError: String?
    public private(set) var isLoadingComments = false
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var configuration: DashboardConfiguration?
    @ObservationIgnored public var onIssuesUpdate: (([JiraIssue]) -> Void)?
    @ObservationIgnored public var onPresentation: (([String: CachedAvatar]) -> Void)?
    @ObservationIgnored private let site: JiraSite
    @ObservationIgnored private let account: String
    @ObservationIgnored private let cache: ConnectionCache
    @ObservationIgnored private let client: JiraClient
    @ObservationIgnored private let token: @Sendable () throws -> String
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var commentGeneration = UUID()
    @ObservationIgnored var currentTask: Task<Void, Never>?
    @ObservationIgnored var commentTask: Task<Void, Never>?
    @ObservationIgnored var completionHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var completionWeekCount = 10
    @ObservationIgnored private var completionHistoryGeneration = UUID()
    @ObservationIgnored private var commentSnapshots: [DashboardCommentScope: CachedDashboardComments] = [:]

    public init(site: JiraSite, account: String, cache: ConnectionCache, client: JiraClient = JiraClient(),
                token: @escaping @Sendable () throws -> String) {
        self.site = site; self.account = account; self.cache = cache; self.client = client; self.token = token
    }

    public var imageURLs: [URL] {
        sections.values.flatMap(\.tableImageURLs) + (comments?.imageURLs ?? [])
            + recent.flatMap { [$0.issue.fields.issuetype?.iconUrl, $0.issue.fields.priority?.iconUrl].compactMap { $0 } }
    }

    public func snapshot(for section: DashboardSection) -> CachedSearch? {
        guard let saved = sections[section] else { return nil }
        let query = configuration.flatMap { try? section.query(projectID: saved.query.projectID, configuration: $0) } ?? saved.query
        var presentation = CachedSearch(query: query, generation: saved.generation, pages: saved.pages,
                                        issueOverrides: saved.issueOverrides)
        guard section == .myIssues else { return presentation }
        let excluded = Set(saved.issues.filter { ["new", "backlog"].contains($0.status.lowercased()) }.map(\.id))
        guard !excluded.isEmpty else { return presentation }
        // Keep the raw response; apply today's section rules to older downloaded snapshots too.
        let total = saved.hasMore ? nil : saved.issues.count - excluded.count
        presentation.pages = saved.pages.map { cached in
            let page = cached.page
            return CachedIssuePage(page: IssuePage(startAt: page.startAt, maxResults: page.maxResults, total: total,
                issues: page.issues.filter { !excluded.contains($0.id) }, warningMessages: page.warningMessages),
                response: cached.response, fetchedAt: cached.fetchedAt)
        }
        return presentation
    }

    public func openProject(_ project: String?) {
        if projectID == project {
            if !isLoading, sections.values.map(\.fetchedAt).min().map({ Date().timeIntervalSince($0) > 300 }) ?? true { refresh() }
            return
        }
        reset()
        projectID = project
        guard let project else { return }
        let request = generation
        isLoading = true
        currentTask = Task {
            do {
                let fields = try await cache.loadDashboardConfiguration(site: site.identifier, account: account)
                try Task.checkCancellation()
                guard generation == request else { return }
                configuration = fields
                for section in DashboardSection.allCases {
                    let saved = try await cache.loadDashboardSection(section, project: project, site: site.identifier, account: account)
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    sections[section] = saved
                }
                let visits = try await cache.recentlyViewed(project: project, site: site.identifier, account: account)
                try Task.checkCancellation()
                guard generation == request else { return }
                recent = visits
                for scope in DashboardCommentScope.allCases {
                    let saved = try await cache.loadDashboardComments(scope: scope, project: project, site: site.identifier, account: account)
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    commentSnapshots[scope] = saved
                }
                comments = commentSnapshots[commentScope]
                let savedCompletion = try await cache.loadDashboardCompletion(project: project, site: site.identifier, account: account)
                try Task.checkCancellation()
                guard generation == request else { return }
                completion = savedCompletion
                await publishImages(request: request)
            } catch is CancellationError { return }
            catch { if generation == request { errorMessage = "Could not read the dashboard cache. \(error.localizedDescription)" } }
            guard generation == request, !Task.isCancelled else { return }
            currentTask = nil
            isLoading = false
            refresh()
        }
    }

    public func reset() {
        currentTask?.cancel(); commentTask?.cancel(); completionHistoryTask?.cancel()
        currentTask = nil; commentTask = nil; completionHistoryTask = nil
        completionHistoryGeneration = UUID()
        generation = UUID(); commentGeneration = UUID()
        projectID = nil; sections = [:]; recent = []; comments = nil; commentSnapshots = [:]
        configuration = nil; errorMessage = nil; commentsError = nil; sectionErrors = [:]
        completion = nil; completionError = nil; isLoadingCompletion = false
        isLoading = false; isLoadingComments = false; loadingSections = []
    }

    public func refresh() {
        guard let project = projectID, !isLoading else { return }
        currentTask?.cancel()
        completionHistoryTask?.cancel()
        completionHistoryTask = nil
        completionHistoryGeneration = UUID()
        isLoadingCompletion = false
        commentTask?.cancel()
        commentTask = nil
        commentGeneration = UUID()
        isLoadingComments = false
        generation = UUID()
        let request = generation
        isLoading = true
        errorMessage = nil
        currentTask = Task {
            defer {
                if generation == request {
                    isLoading = false
                    currentTask = nil
                    ensureCompletionWeeks(completionWeekCount)
                }
            }
            do {
                let credential = try await credentials()
                if configuration == nil || Date().timeIntervalSince(configuration!.fetchedAt) >= 86_400 {
                    let fresh = try await client.dashboardConfiguration(site: site, token: credential)
                    try Task.checkCancellation()
                    try await cache.saveDashboardConfiguration(fresh, site: site.identifier, account: account)
                    guard generation == request else { return }
                    configuration = fresh
                }
                guard let configuration else { return }
                refreshComments()
                async let mine: Void = fetch(.myIssues, project: project, configuration: configuration, token: credential, request: request)
                async let next: Void = fetch(.upNext, project: project, configuration: configuration, token: credential, request: request)
                async let done: Void = fetch(.recentlyDone, project: project, configuration: configuration, token: credential, request: request)
                async let statistics: Void = fetchCompletion(project: project, configuration: configuration, token: credential, request: request)
                _ = await (mine, next, done, statistics)
            } catch is CancellationError { }
            catch { if generation == request { errorMessage = message(error) } }
        }
    }

    private func fetch(_ section: DashboardSection, project: String, configuration: DashboardConfiguration,
                       token: String, request: UUID) async {
        loadingSections.insert(section)
        sectionErrors[section] = nil
        defer { if generation == request { loadingSections.remove(section) } }
        do {
            let query = try section.query(projectID: project, configuration: configuration)
            let page = try await client.search(site: site, token: token, query: query)
            try Task.checkCancellation()
            guard generation == request else { return }
            let saved = CachedSearch(query: query, generation: UUID(), pages: [page])
            try await cache.saveDashboardSection(saved, section: section, site: site.identifier, account: account)
            let restored = try await cache.loadDashboardSection(section, project: project, site: site.identifier, account: account)
            try Task.checkCancellation()
            guard generation == request else { return }
            sections[section] = restored
            onIssuesUpdate?(restored?.issues ?? [])
            await publishImages(request: request)
        } catch is CancellationError { }
        catch { if generation == request { sectionErrors[section] = message(error) } }
    }

    private func fetchCompletion(project: String, configuration: DashboardConfiguration, token: String, request: UUID, reuse: Bool = false) async {
        isLoadingCompletion = true
        completionError = nil
        defer { if generation == request { isLoadingCompletion = false } }
        do {
            let count = max(completionWeekCount, completion?.weeks.count ?? 0)
            let saved = try await client.dashboardCompletion(site: site, token: token, projectID: project, configuration: configuration,
                                                             weekCount: count, reusing: reuse ? completion : nil)
            try Task.checkCancellation()
            guard generation == request else { return }
            try await cache.saveDashboardCompletion(saved, project: project, site: site.identifier, account: account)
            try Task.checkCancellation()
            guard generation == request else { return }
            completion = saved
        } catch is CancellationError { }
        catch { if generation == request { completionError = message(error) } }
    }

    public func ensureCompletionWeeks(_ count: Int) {
        completionWeekCount = max(2, count)
        guard let project = projectID, let configuration, let completion,
              completion.weeks.count < completionWeekCount, !isLoading, !isLoadingCompletion,
              completionError == nil else { return }
        completionHistoryTask?.cancel()
        completionHistoryGeneration = UUID()
        let historyRequest = completionHistoryGeneration
        let request = generation
        completionHistoryTask = Task {
            defer {
                if completionHistoryGeneration == historyRequest, generation == request {
                    completionHistoryTask = nil
                    if completionError == nil { ensureCompletionWeeks(completionWeekCount) }
                }
            }
            do {
                // Resizing a window should request only the final visible range.
                try await Task.sleep(for: .milliseconds(250))
                let credential = try await credentials()
                guard generation == request else { return }
                await fetchCompletion(project: project, configuration: configuration, token: credential, request: request, reuse: true)
            } catch is CancellationError { }
            catch { if generation == request { completionError = message(error) } }
        }
    }

    public func selectCommentScope(_ scope: DashboardCommentScope) {
        guard commentScope != scope else { return }
        commentScope = scope
        comments = commentSnapshots[scope]
        refreshComments()
    }

    public func refreshComments(append: Bool = false) {
        commentTask?.cancel()
        commentGeneration = UUID()
        let request = commentGeneration
        let projectRequest = generation
        guard let project = projectID, let configuration else { isLoadingComments = false; return }
        let scope = commentScope
        let previous = append ? comments : nil
        isLoadingComments = true
        commentsError = nil
        commentTask = Task {
            defer { if commentGeneration == request { isLoadingComments = false; commentTask = nil } }
            do {
                let credential = try await credentials()
                var snapshot = previous ?? CachedDashboardComments(scope: scope, pages: [], since: Date().addingTimeInterval(-7 * 86_400))
                // Bound each refresh. The user can continue scanning a very busy project.
                for _ in 0..<3 {
                    let page = try await client.dashboardCommentPage(site: site, token: credential, projectID: project,
                        scope: scope, configuration: configuration, startAt: snapshot.nextStartAt)
                    try Task.checkCancellation()
                    guard commentGeneration == request, generation == projectRequest else { return }
                    snapshot.pages.append(page)
                    try await cache.saveDashboardComments(snapshot, project: project, site: site.identifier, account: account)
                    guard commentGeneration == request, generation == projectRequest else { return }
                    commentSnapshots[scope] = snapshot
                    comments = snapshot
                    onIssuesUpdate?(page.issues.page.issues)
                    await publishImages(request: projectRequest)
                    if !snapshot.needsMoreIssues { break }
                }
            } catch is CancellationError { }
            catch { if commentGeneration == request { commentsError = message(error) } }
        }
    }

    public func recordViewed(_ issue: JiraIssue, project: String) {
        let date = Date()
        if projectID == project {
            recent.removeAll { $0.id == issue.key }
            recent.insert(ViewedIssue(issue: issue, viewedAt: date), at: 0)
            recent = Array(recent.prefix(20))
        }
        Task {
            do {
                try await cache.recordIssueVisit(issue, project: project, site: site.identifier, account: account, at: date)
            } catch {
                if projectID == project { errorMessage = "Could not save recently viewed issues. \(error.localizedDescription)" }
            }
        }
    }

    public func applyKnownIssues(_ issues: [JiraIssue]) {
        for section in DashboardSection.allCases { sections[section] = sections[section]?.reconciling(issues) }
        let latest = Dictionary(issues.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        recent = recent.map { visit in
            ViewedIssue(issue: latest[visit.id].map { visit.issue.accepting($0) } ?? visit.issue, viewedAt: visit.viewedAt)
        }
    }

    private func publishImages(request: UUID) async {
        let images = (try? await cache.loadBoardImages(site: site.identifier, account: account, urls: imageURLs)) ?? [:]
        guard generation == request, !Task.isCancelled else { return }
        onPresentation?(images)
    }

    private func credentials() async throws -> String {
        let token = try await Task.detached { [token] in try token() }.value
        try Task.checkCancellation()
        return token
    }

    private func message(_ error: Error) -> String {
        if error is URLError { return "Cannot reach Jira. Showing downloaded data." }
        return error.localizedDescription
    }
}
