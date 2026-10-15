import FjiraCore
import FjiraUI
import SwiftUI

struct BoardToolbar: ToolbarContent {
    @Bindable var reader: BoardReader
    let commands: JiraCommandContext

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Board", selection: Binding(
                get: { reader.selectedBoardID }, set: { reader.selectBoard($0) }
            )) {
                if reader.selectedBoardID == nil { Text("Select a board").tag(nil as Int?) }
                ForEach(reader.boards) { board in Text(board.name).tag(Optional(board.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(reader.boards.isEmpty)
            .help("Select a board")
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter cards", text: $reader.filterText)
                    .textFieldStyle(.plain)
            }
            .frame(width: 150)
            .help("Filter downloaded cards by issue key or title")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $reader.onlyMyIssues) {
                Label("Only my issues", systemImage: "person.crop.circle")
            }
            .toggleStyle(.button)
            .help("Only my issues")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Refresh board list", systemImage: "arrow.clockwise") { reader.refreshBoards() }
                    .disabled(reader.isLoadingBoards)
            } label: { Label("Board options", systemImage: "ellipsis") }
            .help("Board options")
            if reader.isLoading || reader.isLoadingBoards {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 28)
                    .accessibilityLabel("Updating")
            }
            JiraCommandIconButton(.refresh, context: commands)
        }
    }
}
