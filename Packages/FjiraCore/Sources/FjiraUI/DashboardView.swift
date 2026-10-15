import AppKit
import FjiraCore
import SwiftUI

public struct DashboardView: View {
    @Bindable private var reader: DashboardReader
    private let images: [String: NSImage]
    private let selectedKey: String?
    private let openIssue: (JiraIssue) -> Void
    private let openComment: (JiraIssue) -> Void
    private let browse: (DashboardSection) -> Void
    private let browseQuery: (ProjectQuery) -> Void

    public init(reader: DashboardReader, images: [String: NSImage], selectedKey: String?,
                openIssue: @escaping (JiraIssue) -> Void,
                openComment: @escaping (JiraIssue) -> Void, browse: @escaping (DashboardSection) -> Void,
                browseQuery: @escaping (ProjectQuery) -> Void = { _ in }) {
        self.reader = reader; self.images = images; self.selectedKey = selectedKey
        self.openIssue = openIssue; self.openComment = openComment; self.browse = browse
        self.browseQuery = browseQuery
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = reader.errorMessage {
                        notice(error, downloaded: reader.sections.values.map(\.fetchedAt).min())
                    }
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 20) {
                            mainColumn(width: geometry.size.width - 380).frame(maxWidth: .infinity)
                            sideColumn.frame(width: 320)
                        }
                    } else {
                        mainColumn(width: geometry.size.width - 40)
                        sideColumn
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 8)
            }
        }
    }

    private func completionSection(width: CGFloat) -> some View {
        let chartWidth = max(0, width - 32)
        let weekCount = max(2, Int((chartWidth + 4) / 48))
        return VStack(alignment: .leading, spacing: 12) {
            if let snapshot = reader.completion {
                completionChart(snapshot, capacity: weekCount)
                if let error = reader.completionError {
                    notice(error, downloaded: snapshot.fetchedAt)
                } else if !snapshot.isCurrentWeek() {
                    notice("Showing the last downloaded weeks.", downloaded: snapshot.fetchedAt)
                }
            } else {
                HStack {
                    Text("Tasks completed per week").font(.headline)
                    Spacer()
                    if reader.isLoading || reader.isLoadingCompletion { ProgressView().controlSize(.small) }
                }
                if let error = reader.completionError {
                    notice(error)
                } else {
                    Text(reader.isLoading ? "Loading completion history…" : "No downloaded completion history.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .dashboardPanel()
        .task(id: weekCount) { reader.ensureCompletionWeeks(weekCount) }
    }

    private func completionChart(_ snapshot: CachedDashboardCompletion, capacity: Int) -> some View {
        let weeks = Array(snapshot.weeks.suffix(capacity))
        let maximum = max(weeks.map(\.count).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tasks completed per week").font(.headline)
                Spacer()
                if reader.isLoadingCompletion { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(weeks) { week in
                    let isCurrent = snapshot.isCurrentWeek() && week.id == snapshot.currentWeek?.id
                    Button { browseQuery(week.period.query) } label: {
                        VStack(spacing: 5) {
                            Text(week.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            ZStack(alignment: .bottom) {
                                Color.clear
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(week.count == 0 ? Color.primary.opacity(0.12) : Color.accentColor.opacity(isCurrent ? 1 : 0.65))
                                    .frame(width: 24, height: max(2, 64 * CGFloat(week.count) / CGFloat(maximum)))
                            }.frame(height: 64)
                            Text(isCurrent ? "This week" : snapshot.label(for: week))
                                .font(.caption2).foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Week of \(snapshot.label(for: week)): \(week.count) completed issues. Click to view.")
                    .accessibilityLabel("Week of \(snapshot.label(for: week)), \(week.count) completed issues")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .help("Monday–Sunday weeks in your Jira timezone: \(snapshot.timeZoneIdentifier)")
    }

    private func mainColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            completionSection(width: width)
            issueSection(.myIssues, subtitle: "Assignee or Implementer", limit: 6)
            issueSection(.upNext, subtitle: "Your issues that haven’t started", limit: 5)
            issueSection(.recentlyDone, subtitle: "Your issues resolved in the last 14 days", limit: 5)
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            recentlyViewed
            newComments
        }
    }

    private func issueSection(_ section: DashboardSection, subtitle: String, limit: Int) -> some View {
        let snapshot = reader.snapshot(for: section)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title).font(.title2.bold())
                    if let total = snapshot?.total {
                        Text(total.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if reader.loadingSections.contains(section) { ProgressView().controlSize(.small) }
                    if snapshot != nil {
                        Button("View all") { browse(section) }.buttonStyle(.link).font(.caption)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            if let error = reader.sectionErrors[section] {
                notice(error, downloaded: snapshot?.fetchedAt).padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let snapshot, !snapshot.issues.isEmpty {
                ForEach(Array(snapshot.issues.prefix(limit))) { issue in
                    Divider().padding(.horizontal, 16)
                    issueRow(issue)
                }
                if snapshot.issues.count > limit {
                    Divider().padding(.horizontal, 16)
                    Button("Show all \(snapshot.total.map(String.init) ?? "") issues") { browse(section) }
                        .buttonStyle(.link).font(.caption).padding(16)
                }
            } else {
                Text(snapshot == nil ? (reader.isLoading ? "Loading issues…" : "No downloaded issues available.") : emptyMessage(section))
                    .foregroundStyle(.secondary).font(.callout).padding(16).padding(.bottom, 6)
            }
        }
        .dashboardPanel()
    }

    private func issueRow(_ issue: JiraIssue) -> some View {
        Button { openIssue(issue) } label: {
            HStack(alignment: .top, spacing: 10) {
                icon(issue.fields.issuetype?.iconUrl, symbol: "square.dashed", size: 16)
                    .padding(.top, 2).help(issue.issueType)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        if issue.isFlagged { IssueFlagIndicator() }
                        Text(issue.summary).font(.system(size: 13)).lineLimit(2)
                            .multilineTextAlignment(.leading).foregroundStyle(.primary)
                    }
                    HStack(spacing: 8) {
                        Text(issue.key).font(.custom("Menlo", size: 10)).foregroundStyle(.secondary)
                        if let epic = issue.epicLink { EpicPill(epic: epic) }
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 7) {
                    StatusPill(name: issue.status, tone: issue.statusTone).frame(maxWidth: 170, alignment: .trailing)
                    HStack(spacing: 7) {
                        icon(issue.fields.priority?.iconUrl, symbol: "minus", size: 14).help(issue.priority)
                        avatar(issue.fields.assignee?.avatarURL, size: 18).help(issue.assignee)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(issue.key == selectedKey ? Color.accentColor.opacity(0.08) : .clear, in: Rectangle())
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.status)")
    }

    private var recentlyViewed: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Recently viewed", systemImage: "clock").font(.headline).padding(16)
            if reader.recent.isEmpty {
                Text("Issues you open will appear here.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ForEach(Array(reader.recent.prefix(6))) { visit in
                    Divider().padding(.horizontal, 16)
                    Button { openIssue(visit.issue) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(visit.issue.summary).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                            HStack {
                                Text(visit.issue.key).font(.custom("Menlo", size: 10))
                                Spacer()
                                Text(visit.viewedAt, style: .date).font(.caption2)
                            }.foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .dashboardPanel()
    }

    private var newComments: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("New comments", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer(minLength: 0)
                if reader.isLoadingComments { ProgressView().controlSize(.small) }
                Picker("Comment activity", selection: Binding(get: { reader.commentScope }, set: { reader.selectCommentScope($0) })) {
                    ForEach(DashboardCommentScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 92)
                .help("My: issues where you are Assignee or Implementer. All: the current project.")
            }.padding(16)
            if let error = reader.commentsError {
                notice(error, downloaded: reader.comments?.fetchedAt).padding(.horizontal, 16).padding(.bottom, 12)
                Button("Retry") { reader.refreshComments() }.buttonStyle(.link).padding(.horizontal, 16).padding(.bottom, 12)
            }
            let comments = Array((reader.comments?.comments ?? []).prefix(20))
            if comments.isEmpty {
                Text(reader.isLoadingComments ? "Looking for recent comments…" : "No comments in downloaded activity.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 16)
            }
            ForEach(comments) { entry in
                Divider().padding(.horizontal, 16)
                Button { openComment(entry.issue) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            avatar(entry.comment.author?.avatarURL, size: 22)
                            Text(entry.comment.authorName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(entry.date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.preview).font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading)
                        Text("\(entry.issue.key) · \(entry.issue.summary)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.date.formatted(date: .abbreviated, time: .shortened))
            }
            if reader.comments?.needsMoreIssues == true && !reader.isLoadingComments {
                Divider().padding(.horizontal, 16)
                Button("Find more recent activity") { reader.refreshComments(append: true) }
                    .buttonStyle(.link).font(.caption).padding(16)
            }
        }
        .dashboardPanel()
    }

    private func notice(_ message: String, downloaded: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            if let downloaded {
                Text("Downloaded \(downloaded.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func emptyMessage(_ section: DashboardSection) -> String {
        switch section {
        case .myIssues: "No current issues."
        case .upNext: "Nothing queued up."
        case .recentlyDone: "No issues resolved in the last 14 days."
        }
    }

    @ViewBuilder private func icon(_ url: URL?, symbol: String, size: CGFloat) -> some View {
        if let url, let image = images[url.absoluteString] {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }

    @ViewBuilder private func avatar(_ url: URL?, size: CGFloat) -> some View {
        if let url, let image = images[url.absoluteString] {
            Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            Image(systemName: PersonAvatarPlaceholder.symbolName).font(.system(size: size))
                .foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

private extension View {
    func dashboardPanel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
    }
}
