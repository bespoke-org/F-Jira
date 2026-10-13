import Foundation
import Observation

@MainActor
@Observable
public final class IssueReader {
    public private(set) var selection: JiraIssue?
    public private(set) var detail: CachedIssueDetail?
    public private(set) var isLoading = false
    public private(set) var isOffline = false
    public private(set) var remoteLinksError: String?
    public private(set) var errorMessage: String?
    public private(set) var avatars: [String: CachedAvatar] = [:]

    @ObservationIgnored private let site: JiraSite
    @ObservationIgnored private let account: String
    @ObservationIgnored private let cache: ConnectionCache
    @ObservationIgnored private let client: JiraClient
    @ObservationIgnored private let token: @Sendable () throws -> String
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored var currentTask: Task<Void, Never>?
    @ObservationIgnored var avatarTask: Task<Void, Never>?
    @ObservationIgnored var remoteLinksTask: Task<Void, Never>?
    @ObservationIgnored private var recentIssues: [String: IssueSnapshot] = [:]
    @ObservationIgnored private var recentIssueOrder: [String] = []

    private struct IssueSnapshot {
        let detail: CachedIssueDetail
        let avatars: [String: CachedAvatar]
    }

    public init(site: JiraSite, account: String, cache: ConnectionCache, client: JiraClient,
                token: @escaping @Sendable () throws -> String) {
        self.site = site
        self.account = account
        self.cache = cache
        self.client = client
        self.token = token
    }

    public func open(_ issue: JiraIssue) {
        cancel()
        selection = issue
        isOffline = false
        let saved = recentIssues[issue.id]
        detail = saved?.detail
        avatars = saved?.avatars ?? [:]
        rememberCurrentIssue()
        refresh()
    }

    public func close() {
        cancel()
        selection = nil
        isOffline = false
        detail = nil
        avatars = [:]
        errorMessage = nil
        remoteLinksError = nil
    }

    public func refresh() {
        guard let selection else { return }
        cancel()
        let generation = requestID
        isLoading = true
        errorMessage = nil
        remoteLinksError = nil
        currentTask = Task {
            defer { if requestID == generation { isLoading = false; currentTask = nil } }
            do {
                if detail == nil {
                    let saved = try await cache.loadIssue(site: site.identifier, account: account, id: selection.id)
                    try Task.checkCancellation()
                    guard requestID == generation else { return }
                    detail = saved
                    rememberCurrentIssue()
                }
                if let detail { loadAvatars(detail) }
                let result = try await client.issue(site: site, token: credentials(), id: selection.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                guard result.issue.id == selection.id else { throw JiraError.invalidResponse }
                try await cache.saveIssue(result, site: site.identifier, account: account)
                let updated = try await cache.loadIssue(site: site.identifier, account: account, id: selection.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                detail = updated
                isOffline = false
                rememberCurrentIssue()
                if let updated {
                    loadAvatars(updated)
                    refreshRemoteLinks(updated, generation: generation)
                }
            } catch { handle(error, generation: generation) }
        }
    }

    public func loadMoreComments() {
        guard let detail, detail.hasMoreComments, !isLoading else { return }
        cancel()
        let generation = requestID
        isLoading = true
        errorMessage = nil
        currentTask = Task {
            defer { if requestID == generation { isLoading = false; currentTask = nil } }
            do {
                let page = try await client.comments(site: site, token: credentials(), id: detail.issue.id, startAt: detail.nextCommentStartAt)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                try await cache.saveComments(page, site: site.identifier, account: account,
                                             id: detail.issue.id, expectedGeneration: detail.generation)
                let updated = try await cache.loadIssue(site: site.identifier, account: account, id: detail.issue.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                self.detail = updated
                isOffline = false
                rememberCurrentIssue()
                if let updated {
                    loadAvatars(updated)
                    refreshRemoteLinks(updated, generation: generation)
                }
            } catch { handle(error, generation: generation) }
        }
    }

    private func refreshRemoteLinks(_ detail: CachedIssueDetail, generation: UUID) {
        remoteLinksTask?.cancel()
        remoteLinksTask = Task {
            do {
                let links = try await client.remoteIssueLinks(site: site, token: credentials(), id: detail.issue.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                try await cache.saveRemoteIssueLinks(links, site: site.identifier, account: account,
                                                    id: detail.issue.id, expectedGeneration: detail.generation)
                let updated = try await cache.loadIssue(site: site.identifier, account: account, id: detail.issue.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                self.detail = updated
                remoteLinksError = nil
                rememberCurrentIssue()
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch {
                guard requestID == generation else { return }
                remoteLinksError = "Could not update issue links. \(error.localizedDescription)"
            }
        }
    }

    private func loadAvatars(_ detail: CachedIssueDetail) {
        avatarTask?.cancel()
        let generation = requestID
        let urls = Array(Set(detail.comments.compactMap { $0.author?.avatarURL })).sorted { $0.absoluteString < $1.absoluteString }
        guard !urls.isEmpty else { return }
        avatarTask = Task {
            var missing: [URL] = []
            for url in urls {
                guard !Task.isCancelled, requestID == generation else { return }
                if let saved = try? await cache.loadAvatar(site: site.identifier, account: account, url: url) {
                    guard !Task.isCancelled, requestID == generation else { return }
                    avatars[url.absoluteString] = saved
                    rememberCurrentIssue()
                    if Date().timeIntervalSince(saved.fetchedAt) > 86_400 { missing.append(url) }
                } else { missing.append(url) }
            }
            guard !missing.isEmpty, !Task.isCancelled, requestID == generation, let credential = try? await credentials() else { return }
            for offset in stride(from: 0, to: missing.count, by: 4) {
                let batch = Array(missing[offset..<min(offset + 4, missing.count)])
                await withTaskGroup(of: (String, CachedAvatar?).self) { group in
                    for url in batch {
                        group.addTask { [client, cache, site, account] in
                            guard !Task.isCancelled, let avatar = try? await client.avatar(site: site, token: credential, url: url) else {
                                return (url.absoluteString, nil)
                            }
                            guard !Task.isCancelled else { return (url.absoluteString, nil) }
                            try? await cache.saveAvatar(avatar, site: site.identifier, account: account, url: url)
                            return (url.absoluteString, avatar)
                        }
                    }
                    for await (url, avatar) in group {
                        if !Task.isCancelled, requestID == generation, let avatar {
                            avatars[url] = avatar
                            rememberCurrentIssue()
                        }
                    }
                }
                if Task.isCancelled || requestID != generation { return }
            }
        }
    }

    private func rememberCurrentIssue() {
        guard let detail, detail.issue.id == selection?.id else { return }
        let id = detail.issue.id
        recentIssues[id] = IssueSnapshot(detail: detail, avatars: avatars)
        recentIssueOrder.removeAll { $0 == id }
        recentIssueOrder.append(id)
        if recentIssueOrder.count > 20 {
            recentIssues.removeValue(forKey: recentIssueOrder.removeFirst())
        }
    }

    private func credentials() async throws -> String {
        // Keychain can wait for user interaction. Keep that wait off the UI thread.
        let credential = try await Task.detached { [token] in try token() }.value
        try Task.checkCancellation()
        return credential
    }

    private func cancel() {
        currentTask?.cancel()
        remoteLinksTask?.cancel()
        remoteLinksTask = nil
        avatarTask?.cancel()
        avatarTask = nil
        currentTask = nil
        requestID = UUID()
        isLoading = false
    }

    private func handle(_ error: Error, generation: UUID) {
        guard requestID == generation, !(error is CancellationError) else { return }
        if let error = error as? URLError {
            guard error.code != .cancelled else { return }
            isOffline = error.code == .notConnectedToInternet || error.code == .networkConnectionLost
            errorMessage = "Cannot reach Jira. Previously downloaded details remain available."
        } else {
            isOffline = false
            if let error = error as? JiraError, error == .notFound {
                errorMessage = "This issue is unavailable or you do not have permission to view it. Previously downloaded details remain available."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
