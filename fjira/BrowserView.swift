import AppKit
import FjiraCore
import FjiraUI
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let showAccount: () -> Void
    @State private var projectFilter = ""
    @State private var showingProjects = false
    @State private var selectedView: BrowserSection? = .dashboard
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    private enum BrowserSection: Hashable {
        case dashboard, issues, boards
        var title: String {
            switch self { case .dashboard: "Dashboard"; case .issues: "Issues"; case .boards: "Boards" }
        }
    }
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
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .tag(BrowserSection.dashboard)
                    Section("Browse") {
                        Label("Issues", systemImage: "list.bullet.rectangle")
                            .tag(BrowserSection.issues)
                        Label("Boards", systemImage: "rectangle.split.3x1")
                            .tag(BrowserSection.boards)
                    }
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
                    ), extendsUnderToolbar: selectedView == .issues) {
                        if selectedView == .dashboard {
                            DashboardView(reader: model.dashboardReader,
                                          images: model.tableImages, selectedKey: model.issueReader.selection?.key,
                                          openIssue: { model.issueReader.open($0) },
                                          openComment: { issue in
                                              model.issueReader.selectActivity(.comments)
                                              model.issueReader.open(issue)
                                          }, browse: { section in
                                              guard let query = model.dashboardReader.snapshot(for: section)?.query else { return }
                                              browse(query)
                                          }, browseQuery: browse)
                        } else if selectedView == .boards {
                            BoardsView(model: model)
                        } else {
                            issueList
                        }
                    } detail: {
                        IssueDetailView(reader: model.issueReader, site: model.connection.site, close: closeIssue, commands: commandContext)
                    }
                } else {
                    ContentUnavailableView("Select a project", systemImage: "folder", description: Text("Choose a project at the bottom of the sidebar to search its issues."))
                }
            }
            .ignoresSafeArea(.container, edges: selectedView == .issues ? .top : [])
            .modifier(TopScrollEdge(soft: true))
            .toolbar {
                JiraNavigationControls(context: commandContext)
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        Text((selectedView ?? .dashboard).title).font(.title2.bold())
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        Text((selectedView ?? .dashboard).title).font(.title2.bold())
                    }
                }
                if model.selectedProject != nil && selectedView != .issues {
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    } else {
                        ToolbarItem(placement: .primaryAction) { Spacer() }
                    }
                    if selectedView == .boards {
                        BoardToolbar(reader: model.boardReader, commands: commandContext)
                    } else if selectedView == .dashboard {
                        ToolbarItemGroup(placement: .primaryAction) {
                            if model.dashboardReader.isLoading {
                                ProgressView().controlSize(.small)
                                    .frame(width: 32, height: 28)
                                    .accessibilityLabel("Updating")
                            }
                            JiraCommandIconButton(.refresh, context: commandContext)
                        }
                    }
                }
            }
        }
        .navigationTitle("")
        .focusedSceneValue(\.jiraCommandContext, commandContext)
        .task { await model.restore() }
        .task(id: selectedView == .boards ? model.selectedProjectID : nil) {
            if selectedView == .boards { model.boardReader.openProject(model.selectedProjectID) }
        }
        .task(id: selectedView == .dashboard ? model.selectedProjectID : nil) {
            if selectedView == .dashboard { model.dashboardReader.openProject(model.selectedProjectID) }
        }
        .onChange(of: selectedView) { _, _ in resetIssueNavigation() }
        .onChange(of: model.boardReader.selectedBoardID) { _, _ in
            if selectedView == .boards { resetIssueNavigation() }
        }
        .onChange(of: model.selectedProjectID) { _, project in
            if project == nil { sidebarVisibility = .all }
        }
        .onChange(of: model.issueReader.selection?.id) { _, _ in
            selectedIssueID = issues.first { $0.key == model.issueReader.selection?.key }?.id
        }
        .onChange(of: model.selectedProjectID) { _, _ in resetIssueNavigation(); sortOrder = [] }
        .onChange(of: model.search?.query) { _, _ in
            if selectedView == .issues { resetIssueNavigation(); sortOrder = [] }
        }
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
                HStack(spacing: 12) {
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
                    TextField("Search titles and descriptions, or enter JQL", text: $model.queryText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                        .help("Type words to search titles and descriptions, or paste JQL. Use text: or jql: to choose explicitly.")
                        .disabled(model.isLoadingCache)
                    Button("Search") { commandContext.perform(.search) }
                        .buttonStyle(.borderedProminent)
                        .help(JiraCommand.search.help)
                        .disabled(!commandContext.isEnabled(.search))
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
            Table(issues, selection: Binding(
                get: { selectedIssueID },
                set: { id in
                    guard id != selectedIssueID else { return }
                    selectedIssueID = id
                    if let issue = issues.first(where: { $0.id == id }) {
                        if model.issueReader.selection?.key != issue.key { model.issueReader.open(issue) }
                    } else if model.issueReader.selection != nil {
                        model.issueReader.close()
                    }
                }
            ), sortOrder: $sortOrder) {
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
                        if issue.isFlagged { IssueFlagIndicator() }
                        Text(issue.summary).lineLimit(1).help(issue.summary)
                    }
                }.width(min: 220, ideal: 380)
                TableColumn("Status", value: \.statusSortKey) { issue in
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
                            Image(systemName: PersonAvatarPlaceholder.symbolName).foregroundStyle(.secondary)
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
            // Column headings need an opaque edge even though the window toolbar uses a soft fade.
            .modifier(TopScrollEdge(soft: false))
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
                Button("Open in Jira") { commandContext.perform(.openInJira) }
                    .disabled(!commandContext.isEnabled(.openInJira))
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
                Button("Open in Jira", systemImage: JiraCommand.openInJira.symbol) { commandContext.perform(.openInJira) }
                    .help(JiraCommand.openInJira.help)
                    .disabled(!commandContext.isEnabled(.openInJira))
            }
            .font(.caption)
            .padding(12)
            .help("Column sorting applies to downloaded rows. Use ORDER BY in JQL to sort the entire search.")
        }
    }

    private func browse(_ query: ProjectQuery) {
        selectedView = .issues
        model.queryText = query.input
        model.runSearch()
    }

    private func resetIssueNavigation() {
        selectedIssueID = nil
        model.issueReader.resetNavigation()
    }

    private func closeIssue() {
        selectedIssueID = nil
        model.issueReader.close()
    }

    private var commandContext: JiraCommandContext {
        let showingBoards = selectedView == .boards
        let showingDashboard = selectedView == .dashboard
        let currentIssue = model.issueReader.selection ?? (selectedView == .issues ? selectedIssue : nil)
        let board = showingBoards ? model.boardReader.selectedBoard : nil
        let canRefreshBoard = showingBoards && model.selectedProject != nil
            && !model.boardReader.isLoading && !model.boardReader.isLoadingBoards
        let canRefreshDashboard = showingDashboard && model.selectedProject != nil && !model.dashboardReader.isLoading
        let canSearch = selectedView == .issues && model.selectedProject != nil && !model.isRestoring
            && !model.isLoadingCache && !model.isSearching
        return JiraCommandContext([
            .toggleSidebar: JiraCommandAction {
                sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
            },
            .closeIssue: JiraCommandAction(isEnabled: model.issueReader.selection != nil) { closeIssue() },
            .goBack: JiraCommandAction(isEnabled: model.issueReader.canGoBack) { model.issueReader.goBack() },
            .goForward: JiraCommandAction(isEnabled: model.issueReader.canGoForward) { model.issueReader.goForward() },
            .openInJira: JiraCommandAction(isEnabled: currentIssue != nil || board != nil) {
                if let currentIssue {
                    NSWorkspace.shared.open(model.connection.site.url.appending(path: "browse/\(currentIssue.key)"))
                } else if let board {
                    NSWorkspace.shared.open(board.webURL(site: model.connection.site))
                }
            },
            .refresh: JiraCommandAction(isEnabled: currentIssue != nil ? !model.issueReader.isLoading : (canSearch || canRefreshBoard || canRefreshDashboard)) {
                if currentIssue != nil { model.issueReader.refresh() }
                else if showingBoards { model.boardReader.refresh() }
                else if showingDashboard { model.dashboardReader.refresh() }
                else { model.runSearch() }
            },
            .search: JiraCommandAction(isEnabled: canSearch) { model.runSearch() }
        ])
    }
}

private struct TopScrollEdge: ViewModifier {
    let soft: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(soft ? .soft : .hard, for: .top)
        } else {
            content
        }
    }
}
