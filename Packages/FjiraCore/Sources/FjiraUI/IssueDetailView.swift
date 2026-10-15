import AppKit
import FjiraCore
import SwiftUI

public struct IssueDetailView: View {
    @Bindable var reader: IssueReader
    let site: JiraSite
    let close: () -> Void
    private let commands: JiraCommandContext?
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastPresentedIssue: JiraIssue?

    public init(reader: IssueReader, site: JiraSite, close: @escaping () -> Void, commands: JiraCommandContext? = nil) {
        self.reader = reader
        self.site = site
        self.close = close
        self.commands = commands
    }

    private var issue: JiraIssue? { reader.detail?.issue.listIssue ?? (reader.isLoading ? lastPresentedIssue : nil) ?? reader.selection }
    private var document: String? {
        reader.detail.map { IssueBodyHTML.document(detail: $0, baseURL: site.url, dark: colorScheme == .dark, avatars: reader.avatars, issueLinksError: reader.remoteLinksError, personPlaceholderDataURL: PersonAvatarPlaceholder.dataURL(dark: colorScheme == .dark), activityTab: reader.activityTab, historyIsLoading: reader.isLoadingHistory || reader.isLoading, historyError: reader.historyError, historyLimit: reader.historyLimit) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(issue?.key ?? "Issue").font(.custom("Menlo", size: 13, relativeTo: .headline).weight(.semibold)).textSelection(.enabled)
                if issue?.isFlagged == true { IssueFlagIndicator() }
                Spacer()
                if reader.isLoading && reader.detail == nil { ProgressView().controlSize(.small) }
                JiraCommandIconButton(.refresh, context: commandContext)
                JiraCommandIconButton(.openInJira, context: commandContext)
                JiraCommandIconButton(.closeIssue, context: commandContext)
            }
            .buttonStyle(.borderless).padding(16)
            Divider()
            if reader.isOffline, let detail = reader.detail {
                Label("Offline (downloaded \(detail.fetchedAt.formatted(date: .abbreviated, time: .shortened)))", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = reader.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                RenderedIssueBody(document: document, documentID: reader.detail?.issue.id, onAction: handleAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(reader.detail != nil)
                if reader.detail == nil && (lastPresentedIssue == nil || !reader.isLoading) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(reader.selection?.summary ?? "Issue").font(.title2.bold()).textSelection(.enabled)
                        if reader.isLoading { ProgressView("Loading details…") }
                        else { Text("Full details have not been downloaded yet. Connect to Jira and refresh to load them.").foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: reader.detail?.issue.id, initial: true) { _, _ in
            if let detail = reader.detail { lastPresentedIssue = detail.issue.listIssue }
        }
    }

    private func handleAction(_ url: URL) {
        if url.host == "activity" || url.host == "history" {
            let issueID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "issue" }?.value
            guard issueID == reader.detail?.issue.id else { return }
            if url.host == "activity", let tab = IssueActivityTab(rawValue: url.lastPathComponent) {
                reader.selectActivity(tab)
            } else if url.host == "history", url.lastPathComponent == "more" {
                reader.showMoreHistory()
            } else if url.host == "history", url.lastPathComponent == "retry" {
                reader.retryHistory()
            }
            return
        }
        if url.host == "epic", url.lastPathComponent == reader.detail?.issue.epicLink?.key {
            reader.openEpic()
            return
        }
        if url.host == "comments" { reader.loadMoreComments(); return }
        guard url.host == "issue", let fields = reader.detail?.issue.fields else { return }
        let candidates = (fields.subtasks ?? []) + (fields.issuelinks ?? []).compactMap(\.relatedIssue)
        if let related = candidates.first(where: { $0.id == url.lastPathComponent }) { reader.open(related) }
    }

    private var commandContext: JiraCommandContext {
        commands ?? JiraCommandContext([
            .closeIssue: JiraCommandAction { close() },
            .refresh: JiraCommandAction(isEnabled: reader.selection != nil && !reader.isLoading) { reader.refresh() },
            .openInJira: JiraCommandAction(isEnabled: reader.selection != nil) { openInJira() }
        ])
    }

    private func openInJira() {
        guard let issue = reader.selection else { return }
        NSWorkspace.shared.open(site.url.appending(path: "browse/\(issue.key)"))
    }
}
