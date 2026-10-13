import FjiraCore
import SwiftUI

struct ContentView: View {
    @State private var model = ConnectionModel()
    @State private var browser: BrowserModel?
    @State private var showingAccount = false

    private var connectionIdentity: String? {
        model.connection.map { "\($0.site.identifier)|\($0.user.identifier)" }
    }

    var body: some View {
        Group {
            if model.isRestoring {
                ProgressView("Opening saved connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.connection != nil {
                if let browser {
                    BrowserView(model: browser) { showingAccount = true }
                } else {
                    ProgressView("Opening projects…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                connectionForm
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.restore() }
        .task(id: connectionIdentity) {
            browser?.stop()
            browser = model.makeBrowser()
            if model.connection == nil { showingAccount = false }
        }
        .sheet(isPresented: $showingAccount) {
            if let connection = model.connection {
                VStack(spacing: 24) {
                    accountView(connection)
                    Button("Done") { showingAccount = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(32)
                .frame(width: 620)
            }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Connect to Jira", systemImage: "network")
                .font(.largeTitle.bold())
            Text("Use your on-premises Jira URL and a personal access token from your Jira profile.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Jira URL")
                TextField("https://jira.company.com/jira", text: $model.baseURL)
                    .textContentType(.URL)
                    .disabled(model.isBusy)
                Text("Include /jira if it is part of your server's base URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Personal access token")
                SecureField("Paste your token", text: $model.token)
                    .disabled(model.isBusy)
                Text("Your token is stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            errorView
            HStack {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.baseURL.isEmpty || model.token.isEmpty)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Checking connection…").foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 440)
    }

    private func accountView(_ connection: CachedConnection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(connection.user.displayName, systemImage: "person.crop.circle")
                .font(.largeTitle.bold())
            Text(connection.site.identifier)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("Account"); Text(connection.user.name) }
                GridRow { Text("Server"); Text(connection.server.serverTitle ?? "Jira") }
                GridRow { Text("Jira version"); Text(connection.server.version) }
            }
            Label(
                model.isVerified ? "Connection verified" : "Showing saved account details",
                systemImage: model.isVerified ? "checkmark.circle" : "internaldrive"
            )
            Text("Last verified: \(connection.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            errorView
            HStack {
                Button("Check connection") { model.refresh() }
                    .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
                Button("Disconnect", role: .destructive) { model.disconnect() }
                    .disabled(model.isBusy)
            }
            Text("Disconnect removes the saved token. Downloaded data stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 540)
    }

    @ViewBuilder
    private var errorView: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    ContentView()
}
