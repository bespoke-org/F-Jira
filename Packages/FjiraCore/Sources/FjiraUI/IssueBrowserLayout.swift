import SwiftUI

public struct IssueBrowserLayout<Issues: View, Detail: View>: View {
    @Binding private var isIssuePresented: Bool
    @State private var usesSidePane = false
    private let extendsUnderToolbar: Bool
    private let issues: () -> Issues
    private let detail: () -> Detail

    public init(isIssuePresented: Binding<Bool>, extendsUnderToolbar: Bool = true, @ViewBuilder issues: @escaping () -> Issues,
                @ViewBuilder detail: @escaping () -> Detail) {
        _isIssuePresented = isIssuePresented
        self.extendsUnderToolbar = extendsUnderToolbar
        self.issues = issues
        self.detail = detail
    }

    public var body: some View {
        HSplitView {
            issues()
                .ignoresSafeArea(.container, edges: extendsUnderToolbar ? .top : [])
                .frame(minWidth: usesSidePane ? 500 : 0)
            if usesSidePane && isIssuePresented {
                detail()
                    .ignoresSafeArea(.container, edges: extendsUnderToolbar ? .top : [])
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Observe only the layout mode, so sidebar animation frames don't rebuild the table or issue body.
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= 940
        } action: { wide in
            usesSidePane = wide
        }
        .sheet(isPresented: Binding(
            get: { !usesSidePane && isIssuePresented },
            set: { presented in if !presented && !usesSidePane { isIssuePresented = false } }
        )) {
            detail().frame(minWidth: 560, idealWidth: 620, minHeight: 500, idealHeight: 700)
        }
    }
}
