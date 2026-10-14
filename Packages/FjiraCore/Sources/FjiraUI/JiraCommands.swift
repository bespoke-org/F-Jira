import SwiftUI

/// Command identity and presentation live here; each window supplies its own actions.
public enum JiraCommand: String, CaseIterable, Identifiable {
    case goBack, goForward, openInJira, refresh, search

    public var id: Self { self }
    public var title: String {
        switch self {
        case .goBack: "Back"
        case .goForward: "Forward"
        case .openInJira: "Open in Jira"
        case .refresh: "Refresh"
        case .search: "Search"
        }
    }
    public var symbol: String {
        switch self {
        case .goBack: "chevron.left"
        case .goForward: "chevron.right"
        case .openInJira: "arrow.up.right.square"
        case .refresh: "arrow.clockwise"
        case .search: "magnifyingglass"
        }
    }
    public var key: KeyEquivalent {
        switch self {
        case .goBack: .leftArrow
        case .goForward: .rightArrow
        case .openInJira: "o"
        case .refresh: "r"
        case .search: .return
        }
    }
    public var modifiers: EventModifiers { .command }
    public var shortcutLabel: String {
        let label: String
        switch key {
        case .leftArrow: label = "←"
        case .rightArrow: label = "→"
        case .return: label = "↩"
        default: label = String(key.character).uppercased()
        }
        return "⌘" + label
    }
    public var help: String { "\(title) (\(shortcutLabel))" }
}

@MainActor
public struct JiraCommandAction {
    public let isEnabled: Bool
    private let action: () -> Void

    public init(isEnabled: Bool = true, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    public func perform() {
        guard isEnabled else { return }
        action()
    }
}

@MainActor
public struct JiraCommandContext {
    private let actions: [JiraCommand: JiraCommandAction]

    public init(_ actions: [JiraCommand: JiraCommandAction]) { self.actions = actions }
    public func isEnabled(_ command: JiraCommand) -> Bool { actions[command]?.isEnabled ?? false }
    public func perform(_ command: JiraCommand) { actions[command]?.perform() }
}

private struct JiraCommandContextKey: FocusedValueKey {
    typealias Value = JiraCommandContext
}

extension FocusedValues {
    public var jiraCommandContext: JiraCommandContext? {
        get { self[JiraCommandContextKey.self] }
        set { self[JiraCommandContextKey.self] = newValue }
    }
}

/// The menu owns keyboard bindings, so toolbar buttons never register duplicate shortcuts.
public struct JiraCommands: Commands {
    @FocusedValue(\.jiraCommandContext) private var context

    public init() {}

    public var body: some Commands {
        CommandMenu("Jira") {
            ForEach(JiraCommand.allCases) { command in
                Button(command.title) { context?.perform(command) }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(context?.isEnabled(command) != true)
            }
        }
    }
}

public struct JiraCommandIconButton: View {
    let command: JiraCommand
    let context: JiraCommandContext

    public init(_ command: JiraCommand, context: JiraCommandContext) {
        self.command = command
        self.context = context
    }

    public var body: some View {
        Button { context.perform(command) } label: { Image(systemName: command.symbol) }
            .help(command.help)
            .accessibilityLabel(command.title)
            .disabled(!context.isEnabled(command))
    }
}
