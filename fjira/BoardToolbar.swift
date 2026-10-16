import AppKit
import FjiraCore
import FjiraUI
import SwiftUI

struct BoardToolbar: ToolbarContent {
    @Bindable var reader: BoardReader
    let commands: JiraCommandContext
    let images: [String: NSImage]

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
                filterField
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                filterField.frame(height: 28)
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                assigneeMenu.glassEffect(.regular.interactive(), in: Circle())
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { assigneeMenu }
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

    private var selectedAssignee: JiraUser? {
        reader.assignees.first { $0.identifier == reader.selectedAssigneeID }
    }

    private var assigneeMenu: some View {
        Menu {
            assigneeOption("All assignees", id: nil)
            Divider()
            ForEach(reader.assignees, id: \.identifier) { user in
                assigneeOption(user.displayName + (user.identifier == reader.currentUserID ? " (Me)" : ""),
                               id: user.identifier)
            }
        } label: {
            Group {
                if let url = selectedAssignee?.avatarURL,
                   let source = images[url.absoluteString],
                   let image = ToolbarAvatarImage.image(from: source) {
                    Image(nsImage: image).renderingMode(.original)
                } else {
                    Image(systemName: selectedAssignee == nil ? "person.2" : PersonAvatarPlaceholder.symbolName)
                        .font(.system(size: 18))
                        .foregroundStyle(selectedAssignee == nil ? Color.secondary : Color.accentColor)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .help(selectedAssignee.map { "Assignee: " + $0.displayName } ?? "All assignees")
        .accessibilityLabel(selectedAssignee.map { "Filter by assignee: " + $0.displayName } ?? "Filter by assignee: All assignees")
    }

    private func assigneeOption(_ title: String, id: String?) -> some View {
        Button { reader.selectedAssigneeID = id } label: {
            if reader.selectedAssigneeID == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
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
