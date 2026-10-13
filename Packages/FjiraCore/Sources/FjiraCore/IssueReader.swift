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
    @ObservationIgnored private var imageMemory: [String: CachedAvatar] = [:]
    @ObservationIgnored private var recentImageURLs: [String] = []
    @ObservationIgnored private var activeImageURLs: [URL] = []
    @ObservationIgnored private var imageGeneration: UUID?

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
        rememberImages(saved?.avatars ?? [:])
        let knownURLs = saved?.detail.imageURLs ?? [issue.fields.issuetype?.iconUrl, issue.fields.priority?.iconUrl,
                                                    issue.fields.assignee?.avatarURL].compactMap { $0 }
        avatars = imagesInMemory(for: knownURLs, cached: saved?.avatars ?? [:])
        detail = saved?.detail
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
                    let saved = try await cache.loadIssuePresentation(site: site.identifier, account: account, id: selection.id)
                    try Task.checkCancellation()
                    guard requestID == generation else { return }
                    if let saved { present(saved.detail, images: saved.images) }
                }
                if let detail { loadAvatars(detail) }
                let result = try await client.issue(site: site, token: credentials(), id: selection.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                guard result.issue.id == selection.id else { throw JiraError.invalidResponse }
                try await cache.saveIssue(result, site: site.identifier, account: account)
                let updated = try await cache.loadIssuePresentation(site: site.identifier, account: account, id: selection.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                isOffline = false
                if let updated {
                    present(updated.detail, images: updated.images)
                    loadAvatars(updated.detail)
                    refreshRemoteLinks(updated.detail, generation: generation)
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
                let updated = try await cache.loadIssuePresentation(site: site.identifier, account: account, id: detail.issue.id)
                try Task.checkCancellation()
                guard requestID == generation else { return }
                isOffline = false
                if let updated {
                    present(updated.detail, images: updated.images)
                    loadAvatars(updated.detail)
                    refreshRemoteLinks(updated.detail, generation: generation)
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

    private func present(_ detail: CachedIssueDetail, images: [String: CachedAvatar]) {
        let combined = imagesInMemory(for: detail.imageURLs, cached: images)
        rememberImages(combined)
        // Publish the image bytes before the issue so its first render is complete.
        avatars = combined
        self.detail = detail
        rememberCurrentIssue()
    }

    private func imagesInMemory(for urls: [URL], cached: [String: CachedAvatar] = [:]) -> [String: CachedAvatar] {
        var result: [String: CachedAvatar] = [:]
        for url in urls {
            let key = url.absoluteString
            if let memory = imageMemory[key], let saved = cached[key] {
                result[key] = memory.fetchedAt > saved.fetchedAt ? memory : saved
            } else {
                result[key] = imageMemory[key] ?? cached[key]
            }
        }
        return result
    }

    private func rememberImages(_ images: [String: CachedAvatar]) {
        for (url, image) in images {
            if let existing = imageMemory[url], existing.fetchedAt > image.fetchedAt { continue }
            imageMemory[url] = image
            recentImageURLs.removeAll { $0 == url }
            recentImageURLs.append(url)
            if recentImageURLs.count > 256 {
                imageMemory.removeValue(forKey: recentImageURLs.removeFirst())
            }
        }
    }

    private func loadAvatars(_ detail: CachedIssueDetail) {
        let generation = requestID
        let urls = detail.imageURLs
        // An issue refresh with the same URLs must not restart in-flight image requests.
        if avatarTask != nil, imageGeneration == generation, activeImageURLs == urls { return }
        avatarTask?.cancel()
        let missing = urls.filter { url in
            guard let image = avatars[url.absoluteString] else { return true }
            return Date().timeIntervalSince(image.fetchedAt) > 86_400
        }
        guard !missing.isEmpty else { avatarTask = nil; return }
        imageGeneration = generation
        activeImageURLs = urls
        avatarTask = Task {
            defer {
                if imageGeneration == generation, activeImageURLs == urls { avatarTask = nil }
            }
            guard !Task.isCancelled, requestID == generation, let credential = try? await credentials() else { return }
            for offset in stride(from: 0, to: missing.count, by: 4) {
                let batch = Array(missing[offset..<min(offset + 4, missing.count)])
                let downloaded = await withTaskGroup(of: (String, CachedAvatar?).self, returning: [String: CachedAvatar].self) { group in
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
                    var result: [String: CachedAvatar] = [:]
                    for await (url, avatar) in group {
                        if let avatar { result[url] = avatar }
                    }
                    return result
                }
                guard !Task.isCancelled, requestID == generation else { return }
                rememberImages(downloaded)
                avatars.merge(downloaded) { _, new in new }
                rememberCurrentIssue()
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
        imageGeneration = nil
        activeImageURLs = []
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
