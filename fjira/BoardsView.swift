import FjiraCore
import FjiraUI
import SwiftUI

struct BoardsView: View {
    @Bindable var model: BrowserModel
    let commands: JiraCommandContext

    private var reader: BoardReader { model.boardReader }

    var body: some View {
        @Bindable var reader = reader
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Spacer()
                    if reader.isLoading || reader.isLoadingBoards { ProgressView().controlSize(.small) }
                    Menu {
                        Button("Refresh board list", systemImage: "arrow.clockwise") { reader.refreshBoards() }
                            .disabled(reader.isLoadingBoards)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Board options")
                    JiraCommandIconButton(.refresh, context: commands)
                    JiraCommandIconButton(.openInJira, context: commands)
                }
                HStack(spacing: 12) {
                    Picker("Board", selection: Binding(
                        get: { reader.selectedBoardID }, set: { reader.selectBoard($0) }
                    )) {
                        if reader.selectedBoardID == nil { Text("Select a board").tag(nil as Int?) }
                        ForEach(reader.boards) { board in Text(board.name).tag(Optional(board.id)) }
                    }
                    .labelsHidden().frame(minWidth: 150, maxWidth: 320)
                    .disabled(reader.boards.isEmpty)
                    Spacer(minLength: 0)
                    TextField("Filter cards", text: $reader.filterText)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 220)
                        .help("Filter downloaded cards by issue key or title")
                    Toggle("Only my issues", isOn: $reader.onlyMyIssues).toggleStyle(.button)
                }
                if reader.isOffline, let snapshot = reader.snapshot {
                    Label("Offline (downloaded \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)))", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = reader.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                }
                if let error = reader.listError, error != reader.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let snapshot = reader.snapshot {
                    ForEach(snapshot.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .padding(16)
            Divider()
            if let snapshot = reader.snapshot {
                if snapshot.configuration.columnConfig.columns.isEmpty {
                    ContentUnavailableView("No columns configured", systemImage: "rectangle.split.3x1",
                                           description: Text("Configure this board's columns in Jira."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BoardCanvas(columns: reader.columns, lanes: reader.lanes, images: model.tableImages,
                                selectedKey: model.issueReader.selection?.key,
                                loadingColumnID: reader.loadingColumnID, columnErrors: reader.columnErrors,
                                canLoadMore: !reader.isLoading,
                                automaticallyLoadMore: reader.filterText.isEmpty && !reader.onlyMyIssues && !reader.isOffline,
                                loadMore: { reader.loadMore(column: $0) },
                                openIssue: { model.issueReader.open($0) })
                        .id(snapshot.board.id)
                }
            } else if reader.isLoading || reader.isLoadingBoards {
                ProgressView("Loading board…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(reader.selectedBoardID == nil ? "No boards available" : "Board unavailable", systemImage: "rectangle.split.3x1")
                } description: {
                    Text(reader.selectedBoardID == nil
                         ? "No downloaded boards for this project. Refresh to find boards you can access in Jira."
                         : "Connect to Jira to download this board for offline use.")
                } actions: {
                    Button("Retry") { reader.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
