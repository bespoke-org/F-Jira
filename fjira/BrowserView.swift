import AppKit
import FjiraCore
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let showAccount: () -> Void
    @State private var projectFilter = ""
    @State private var selectedIssueID: String?
    @State private var sortOrder: [KeyPathComparator<JiraIssue>] = []

    private var filteredProjects: [JiraProject] {
        model.projects.filter {
            projectFilter.isEmpty || $0.key.localizedCaseInsensitiveContains(projectFilter)
                || $0.name.localizedCaseInsensitiveContains(projectFilter)
        }
    }
    private var issues: [JiraIssue] { (model.search?.issues ?? []).sorted(using: sortOrder) }
    private var selectedIssue: JiraIssue? { issues.first { $0.id == selectedIssueID } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Filter projects", text: $projectFilter)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                List(selection: Binding(get: { model.selectedProjectID }, set: { model.selectProject($0) })) {
                    ForEach(filteredProjects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.key).font(.headline)
                            Text(project.name).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(project.id)
                    }
                }
                .disabled(model.isRestoring)
                if model.projects.isEmpty {
                    Text(model.isLoadingProjects ? "Loading projects…" : "No downloaded projects")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let message = model.projectError {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    if let date = model.projectsFetchedAt {
                        Text("Projects updated \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Refresh projects", systemImage: "arrow.clockwise") { model.refreshProjects() }
                            .disabled(model.isLoadingProjects)
                        if model.isLoadingProjects { ProgressView().controlSize(.small) }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Projects")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if model.isRestoring {
                ProgressView("Opening downloaded data…")
            } else if let project = model.selectedProject {
                issueList(project)
            } else {
                ContentUnavailableView("Select a project", systemImage: "folder", description: Text("Choose a project to browse its issues using JQL."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button(model.connection.user.displayName, systemImage: "person.crop.circle", action: showAccount)
            }
        }
        .task { await model.restore() }
        .onChange(of: model.selectedProjectID) { _, _ in selectedIssueID = nil; sortOrder = [] }
        .onChange(of: model.search?.query) { _, _ in selectedIssueID = nil; sortOrder = [] }
    }

    private func issueList(_ project: JiraProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.title2.bold())
                        Text("Project: \(project.key)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Downloaded searches", systemImage: "clock") {
                        ForEach(model.history, id: \.query) { saved in
                            Button(saved.query.input.isEmpty ? "All issues" : saved.query.input) {
                                model.openCachedSearch(saved.query.input)
                            }
                        }
                    }
                    .disabled(model.history.isEmpty || model.isLoadingCache)
                }
                HStack {
                    TextField("JQL filter, e.g. assignee = currentUser() ORDER BY updated DESC", text: $model.queryText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                        .disabled(model.isLoadingCache)
                    Button("Run") { model.runSearch() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isLoadingCache)
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelSearch() }
                    }
                }
                Text("The selected project is always included. Leave the filter empty to show all its issues.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let search = model.search {
                    ForEach(Array(Set(search.pages.flatMap { $0.page.warningMessages ?? [] })).sorted(), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Results for: \(search.query.jql)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            Divider()
            Table(issues, selection: $selectedIssueID, sortOrder: $sortOrder) {
                TableColumn("Key", value: \.key).width(min: 90, ideal: 110)
                TableColumn("Summary", value: \.summary) { issue in
                    Text(issue.summary).help(issue.summary)
                }.width(min: 220, ideal: 380)
                TableColumn("Status", value: \.status).width(min: 90, ideal: 120)
                TableColumn("Assignee", value: \.assignee).width(min: 110, ideal: 150)
                TableColumn("Priority", value: \.priority).width(min: 75, ideal: 90)
                TableColumn("Updated", value: \.updated) { issue in
                    Text(issue.updated == .distantPast ? "—" : issue.updated.formatted(date: .abbreviated, time: .shortened))
                }.width(min: 140, ideal: 160)
            }
            .overlay {
                if issues.isEmpty {
                    if model.isSearching || model.isLoadingCache {
                        ProgressView("Loading issues…")
                    } else if model.search != nil {
                        ContentUnavailableView("No matching issues", systemImage: "magnifyingglass", description: Text("Try a different JQL filter."))
                    } else {
                        ContentUnavailableView("Run a search", systemImage: "magnifyingglass", description: Text("Run JQL online, or open a previously downloaded search."))
                    }
                }
            }
            .contextMenu {
                Button("Open in Jira") { openSelectedIssue() }.disabled(selectedIssue == nil)
                Button("Copy issue key") {
                    if let selectedIssue {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedIssue.key, forType: .string)
                    }
                }.disabled(selectedIssue == nil)
            }
            Divider()
            HStack {
                if let search = model.search {
                    Text("\(issues.count) downloaded" + (search.total.map { " of \($0)" } ?? ""))
                    Text("· Updated \(search.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                    if search.hasMore {
                        Button("Load more") { model.loadMore() }
                            .disabled(model.isSearching || model.isLoadingCache)
                    }
                }
                Spacer()
                Button("Open in Jira", systemImage: "arrow.up.right.square") { openSelectedIssue() }
                    .disabled(selectedIssue == nil)
            }
            .font(.caption)
            .padding(12)
            .help("Column sorting applies to downloaded rows. Use ORDER BY in JQL to sort the entire search.")
        }
        .navigationTitle(project.key)
    }

    private func openSelectedIssue() {
        guard let selectedIssue else { return }
        NSWorkspace.shared.open(model.connection.site.url.appending(path: "browse/\(selectedIssue.key)"))
    }
}
