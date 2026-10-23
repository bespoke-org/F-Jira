import AppKit
import FjiraCore
import FjiraUI
import SwiftUI

struct BoardToolbar: ToolbarContent {
    @Bindable var reader: BoardReader
    let commands: JiraCommandContext
    let images: [String: NSImage]
    let isRefreshing: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Board", selection: Binding(
                get: { reader.selectedBoardID }, set: { reader.selectBoard($0) }
            )) {
                if reader.selectedBoardID == nil { Text("Select a board").tag(nil as Int?) }
                ForEach(reader.boards) { board in Text(board.name).tag(Optional(board.id)) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(reader.boards.isEmpty)
            .help("Select a board")
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                filterField
                    .frame(height: 36)
                    .background(ToolbarGlassBackground())
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                filterField.frame(height: 28)
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                assigneeMenu.background(ToolbarGlassBackground())
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { assigneeMenu }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            JiraCommandIconButton(.refresh, context: commands,
                                  isLoading: isRefreshing)
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
        BoardFilterField(text: $reader.filterText)
    }
}
