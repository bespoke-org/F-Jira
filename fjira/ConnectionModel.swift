import FjiraCore
import Foundation
import Observation

@MainActor
@Observable
final class ConnectionModel {
    var baseURL = ""
    var token = ""
    private(set) var connection: CachedConnection?
    private(set) var isBusy = false
    private(set) var isRestoring = true
    private(set) var isVerified = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let client = JiraClient()
    @ObservationIgnored private let tokenStore = TokenStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var cache: ConnectionCache?
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    func restore() async {
        guard isRestoring else { return }
        defer { isRestoring = false }
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "fjira", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cache = try ConnectionCache(path: directory.appending(path: "cache.sqlite").path)
            baseURL = defaults.string(forKey: "lastJiraSite") ?? ""
            guard let site = defaults.string(forKey: "activeJiraSite"),
                  let account = defaults.string(forKey: "activeJiraAccount") else { return }
            connection = try await cache?.load(site: site, account: account)
            baseURL = site
        } catch {
            errorMessage = "Could not open the local cache. \(error.localizedDescription)"
        }
    }

    func connect() {
        let inputURL = baseURL
        let inputToken = token
        start { [self] in
            let site = try JiraSite(inputURL)
            try await verify(site: site, token: inputToken)
        }
    }

    func refresh() {
        guard let connection else { return }
        start { [self] in
            guard let token = try tokenStore.load(
                site: connection.site.identifier, account: connection.user.identifier
            ) else { throw JiraError.missingToken }
            try await verify(site: connection.site, token: token)
        }
    }

    func disconnect() {
        guard let connection else { return }
        do {
            try tokenStore.delete(site: connection.site.identifier, account: connection.user.identifier)
            defaults.removeObject(forKey: "activeJiraSite")
            defaults.removeObject(forKey: "activeJiraAccount")
            self.connection = nil
            token = ""
            isVerified = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeBrowser() -> BrowserModel? {
        guard let connection, let cache else { return nil }
        return BrowserModel(connection: connection, cache: cache)
    }

    func cancel() {
        requestTask?.cancel()
    }

    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !isRestoring, cache != nil else { return }
        isBusy = true
        errorMessage = nil
        isVerified = false
        requestTask = Task {
            defer { isBusy = false; requestTask = nil }
            do { try await operation() }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                    errorMessage = "Cannot reach Jira. Check your internet connection, VPN, and server URL. Downloaded data remains available."
                case .timedOut:
                    errorMessage = "Jira did not respond in time. Try again. Downloaded data remains available."
                case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                    errorMessage = "macOS does not trust this Jira server's certificate. Check your company's certificate setup."
                default:
                    errorMessage = "Could not connect to Jira. Check your network and server URL."
                }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func verify(site: JiraSite, token: String) async throws {
        let result = try await client.verify(site: site, token: token)
        try Task.checkCancellation()
        guard let cache else { return }
        try await cache.save(result)
        try Task.checkCancellation()
        try tokenStore.save(
            token.trimmingCharacters(in: .whitespacesAndNewlines),
            site: site.identifier, account: result.user.identifier
        )
        defaults.set(site.identifier, forKey: "lastJiraSite")
        defaults.set(site.identifier, forKey: "activeJiraSite")
        defaults.set(result.user.identifier, forKey: "activeJiraAccount")
        connection = result
        baseURL = site.identifier
        self.token = ""
        isVerified = true
    }
}
