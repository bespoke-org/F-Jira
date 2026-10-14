import AppKit
import FjiraCore
import FjiraUI
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let showAccount: () -> Void
    @State private var projectFilter = ""
    @State private var showingProjects = false
    @State private var selectedView: BrowserSection? = .issues
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    private enum BrowserSection: Hashable { case issues }
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
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(spacing: 0) {
                List(selection: $selectedView) {
                    Label("Issues", systemImage: "list.bullet.rectangle")
                        .tag(BrowserSection.issues)
                }
                .listStyle(.sidebar)
                Divider()
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            Group {
                if model.isRestoring {
                    ProgressView("Opening downloaded data…")
                } else if model.selectedProject != nil {
                    IssueBrowserLayout(isIssuePresented: Binding(
                        get: { model.issueReader.selection != nil },
                        set: { presented in if !presented { closeIssue() } }
                    )) {
                        issueList
                    } detail: {
                        IssueDetailView(reader: model.issueReader, site: model.connection.site, close: closeIssue)
                    }
                } else {
                    ContentUnavailableView("Select a project", systemImage: "folder", description: Text("Choose a project at the bottom of the sidebar to search its issues."))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle("")
        .task { await model.restore() }
        .onChange(of: model.selectedProjectID) { _, project in
            if project == nil { sidebarVisibility = .all }
        }
        .onChange(of: selectedIssueID) { _, _ in
            if let selectedIssue { model.issueReader.open(selectedIssue) }
            else { model.issueReader.close() }
        }
        .onChange(of: model.selectedProjectID) { _, _ in closeIssue(); sortOrder = [] }
        .onChange(of: model.search?.query) { _, _ in closeIssue(); sortOrder = [] }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 2) {
            Button { showingProjects.toggle() } label: {
                HStack(spacing: 10) {
                    projectImage(model.selectedProject, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedProject?.name ?? "Select a project")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if let project = model.selectedProject {
                            Text(project.key).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .help("Change project")
            .accessibilityLabel("\(model.selectedProject?.name ?? "Select a project"), change project")
            .disabled(model.isRestoring)
            .popover(isPresented: $showingProjects, arrowEdge: .trailing) { projectPicker }
            .task(id: model.selectedProject?.avatarURL) {
                if let project = model.selectedProject { model.loadProjectAvatar(project) }
            }

            Button(action: showAccount) {
                HStack(spacing: 10) {
                    if let data = model.accountAvatar?.data, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 24, height: 24).clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 24)).frame(width: 24, height: 24)
                    }
                    Text(model.connection.user.displayName)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .help("Account")
            .accessibilityLabel("\(model.connection.user.displayName), account")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(8)
    }

    @ViewBuilder
    private func projectImage(_ project: JiraProject?, size: CGFloat) -> some View {
        if let url = project?.avatarURL, let data = model.projectAvatars[url]?.data,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var projectPicker: some View {
        VStack(spacing: 0) {
            TextField("Search projects", text: $projectFilter)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredProjects) { project in
                        Button {
                            if model.selectedProjectID != project.id { model.selectProject(project.id) }
                            showingProjects = false
                        } label: {
                            HStack(spacing: 10) {
                                projectImage(project, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).lineLimit(1)
                                    Text(project.key).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedProjectID == project.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                            .background(model.selectedProjectID == project.id ? Color.accentColor.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRestoring)
                        .onAppear { model.loadProjectAvatar(project) }
                    }
                    if filteredProjects.isEmpty {
                        Text(model.isLoadingProjects ? "Loading projects…" : "No matching projects")
                            .foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.projectError {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Refresh projects", systemImage: "arrow.clockwise") { model.refreshProjects() }
                        .disabled(model.isLoadingProjects)
                    Spacer()
                    if model.isLoadingProjects { ProgressView().controlSize(.small) }
                }
                if let date = model.projectsFetchedAt {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 360, height: 420)
        .onDisappear { projectFilter = "" }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Issues").font(.title2.bold())
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
                .padding(.leading, sidebarVisibility == .detailOnly ? 128 : 0)
                HStack {
                    TextField("Search titles and descriptions, or enter JQL", text: $model.queryText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                        .help("Type words to search titles and descriptions, or paste JQL. Use text: or jql: to choose explicitly.")
                        .disabled(model.isLoadingCache)
                    Button("Search") { model.runSearch() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isLoadingCache)
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelSearch() }
                    }
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let search = model.search {
                    ForEach(Array(Set(search.pages.flatMap { $0.page.warningMessages ?? [] })).sorted(), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let text = search.query.searchText {
                        Text(text.isEmpty ? "All issues" : "Title or description: \(text)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("Results for: \(search.query.jql)")
                            .font(.custom("Menlo", size: 11, relativeTo: .caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
            Divider()
            Table(issues, selection: $selectedIssueID, sortOrder: $sortOrder) {
                TableColumn("Key", value: \.key).width(min: 90, ideal: 110)
                TableColumn("Summary", value: \.summary) { issue in
                    HStack(spacing: 6) {
                        if let url = issue.fields.issuetype?.iconUrl,
                           let image = model.tableImages[url.absoluteString] {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 16, height: 16)
                                .help(issue.issueType).accessibilityLabel(issue.issueType)
                        } else {
                            Image(systemName: "square.dashed").foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .help(issue.issueType).accessibilityLabel(issue.issueType)
                        }
                        Text(issue.summary).lineLimit(1).help(issue.summary)
                    }
                }.width(min: 220, ideal: 380)
                TableColumn("Status", value: \.status) { issue in
                    StatusPill(name: issue.status, tone: issue.statusTone)
                }.width(min: 100, ideal: 140)
                TableColumn("Assignee", value: \.assignee) { issue in
                    HStack(spacing: 6) {
                        if let url = issue.fields.assignee?.avatarURL,
                           let image = model.tableImages[url.absoluteString] {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 20, height: 20).clipShape(Circle())
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                .frame(width: 20, height: 20).accessibilityHidden(true)
                        }
                        Text(issue.assignee).lineLimit(1).help(issue.assignee)
                    }
                }.width(min: 110, ideal: 150)
                TableColumn("Priority", value: \.priority) { issue in
                    HStack(spacing: 6) {
                        if let url = issue.fields.priority?.iconUrl,
                           let image = model.tableImages[url.absoluteString] {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                        } else {
                            Color.clear.frame(width: 16, height: 16)
                        }
                        Text(issue.priority).lineLimit(1).help(issue.priority)
                    }
                }.width(min: 90, ideal: 115)
                TableColumn("Updated", value: \.updated) { issue in
                    Text(issue.updated == .distantPast ? "—" : issue.updated.formatted(date: .abbreviated, time: .shortened))
                }.width(min: 140, ideal: 160)
            }
            .overlay {
                if issues.isEmpty {
                    if model.isSearching || model.isLoadingCache {
                        ProgressView("Loading issues…")
                    } else if model.search != nil {
                        ContentUnavailableView("No matching issues", systemImage: "magnifyingglass", description: Text("Try different words or a JQL filter."))
                    } else {
                        ContentUnavailableView("Run a search", systemImage: "magnifyingglass", description: Text("Search by title, description, or JQL, or open a downloaded search."))
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
    }

    private func closeIssue() {
        selectedIssueID = nil
        model.issueReader.close()
    }

    private func openSelectedIssue() {
        guard let selectedIssue else { return }
        NSWorkspace.shared.open(model.connection.site.url.appending(path: "browse/\(selectedIssue.key)"))
    }
}
