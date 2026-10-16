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
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                filterControls
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                filterControls.frame(height: 28)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if reader.isLoading || reader.isLoadingBoards {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 28)
                    .accessibilityLabel("Updating")
            }
            JiraCommandIconButton(.refresh, context: commands)
        }
    }

    private var filterControls: some View {
        HStack(spacing: 0) {
            filterField
            Toggle(isOn: $reader.onlyMyIssues) {
                Label("Only my issues", systemImage: "person.crop.circle")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .frame(width: 32, height: 28)
            .padding(.trailing, 4)
            .help("Only my issues")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            TextField("Filter cards", text: $reader.filterText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(width: 150)
        .help("Filter downloaded cards by issue key or title")
    }
}
