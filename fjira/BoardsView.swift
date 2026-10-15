import FjiraCore
import FjiraUI
import SwiftUI

struct BoardsView: View {
    @Bindable var model: BrowserModel

    private var reader: BoardReader { model.boardReader }

    private var hasNotice: Bool {
        reader.isOffline || reader.errorMessage != nil || reader.listError != nil
            || !(reader.snapshot?.warnings.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasNotice {
                VStack(alignment: .leading, spacing: 12) {
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
            }
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
