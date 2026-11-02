import SwiftUI

struct AccessView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var showInstaller = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isMockMode {
                Label(L10n.text("Local test environment"), systemImage: "hammer").font(.callout).foregroundStyle(.secondary)
                Text(L10n.text("Uses temporary keys without accessing your vault.")).font(.caption).foregroundStyle(.secondary)
            } else if model.isDetecting {
                Label(L10n.text("Checking CLI…"), systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
            } else if !model.cliReady {
                stepTitle("1", L10n.text("Set up the CLI"))
                Text(model.cliProblem ?? L10n.text("Install a compatible CLI to connect to your vault."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("Install Compatible CLI"), systemImage: "arrow.down.circle") { showInstaller = true }
                    .primaryActionStyle()
                Button(L10n.text("Check Again")) { Task { await model.detectAndRetry() } }.buttonStyle(.borderless)
            } else if model.bwStatus?.status == "unauthenticated" {
                stepTitle("2", L10n.text("Sign in to your vault"))
                Text(L10n.text("Run this command in Terminal to sign in and complete two-factor authentication."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.loginCommand).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                CopyButton(title: L10n.text("Copy Login Command"), value: model.loginCommand, compact: true)
                Button(L10n.text("I've Signed In — Check Again")) { Task { await model.detectAndRetry() } }.primaryActionStyle()
            } else if model.hasSession {
                if model.agent.status.state == "error" {
                    Button(L10n.text("Retry Loading"), systemImage: "arrow.clockwise") { Task { await model.refreshKeys() } }
                        .primaryActionStyle().disabled(model.isBusy)
                    Button(L10n.text("Unlock Again")) { model.lock(); passwordFocused = true }.buttonStyle(.borderless)
                } else {
                    Text(L10n.text("Private keys stay in agent memory. Each caller needs approval before its first signature."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                stepTitle("3", L10n.text("Unlock your keys"))
                SecureField(L10n.text("Bitwarden master password"), text: $password)
                    .textFieldStyle(.roundedBorder).focused($passwordFocused)
                    .disabled(model.isUnlocking).onSubmit(unlock)
                    .accessibilityLabel(L10n.text("Bitwarden master password"))
                HStack {
                    Button(model.isUnlocking ? L10n.text("Unlocking…") : L10n.text("Unlock"), action: unlock)
                        .primaryActionStyle().disabled(password.isEmpty || model.isBusy)
                    if model.isUnlocking {
                        Button(L10n.text("Cancel")) { model.lock() }.buttonStyle(.borderless)
                    } else {
                        Button(L10n.text("Check Login")) { Task { await model.detectAndRetry() } }.buttonStyle(.borderless)
                    }
                }
                Text(L10n.text("The session is stored in macOS Keychain. Locking stops signing and deletes the saved session."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showInstaller) { InstallerSheet() }
    }

    private func stepTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
            Text(title).font(.headline)
        }
    }
    private func unlock() {
        guard !password.isEmpty, !model.isBusy else { return }
        let value = password
        password = ""
        Task { await model.unlock(password: value) }
    }
}

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Connect SSH"), systemImage: "terminal").font(.title3.weight(.semibold))
            Text(L10n.text("Add this to ~/.ssh/config. Replace any existing IdentityAgent path."))
                .font(.callout).foregroundStyle(.secondary)
            Text(model.sshConfiguration).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                CopyButton(title: L10n.text("Copy SSH Config"), value: model.sshConfiguration)
                Spacer()
                Button(model.isCheckingConnection ? L10n.text("Checking…") : L10n.text("Test Agent Connection")) {
                    Task { await model.checkConnection() }
                }
                .disabled(model.agent.status.state != "ready" || model.isCheckingConnection)
            }
            if let result = model.connectionCheck {
                Text(result).font(.callout).textSelection(.enabled)
            }
            DisclosureGroup(L10n.text("Use in Terminal")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Applies only to the current terminal session:")).font(.caption).foregroundStyle(.secondary)
                    let command = "export SSH_AUTH_SOCK=\(AppModel.shellQuote(model.agent.socketPath))"
                    Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    CopyButton(title: L10n.text("Copy Shell Command"), value: command, compact: true)
                }.padding(.top, 8)
            }
            .font(.callout)
        }
    }
}
