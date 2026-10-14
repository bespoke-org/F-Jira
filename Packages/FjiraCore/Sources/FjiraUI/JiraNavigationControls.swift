import SwiftUI

public struct JiraNavigationControls: ToolbarContent {
    private let context: JiraCommandContext

    public init(context: JiraCommandContext) { self.context = context }

    public var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            JiraCommandIconButton(.goBack, context: context)
            JiraCommandIconButton(.goForward, context: context)
        }
    }
}
