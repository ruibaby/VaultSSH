import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pathDraft = ""
    @State private var showInstaller = false
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner().padding(.horizontal, 20)
            Form {
                Section {
                    TextField(L10n.text("Custom CLI Path"), text: $pathDraft, prompt: Text(L10n.text("Leave empty to detect automatically")))
                        .disabled(saving || model.isInstalling)
                    LabeledContent(L10n.text("Current CLI"), value: model.cliPath ?? L10n.text("Not detected"))
                        .font(.callout).textSelection(.enabled)
                    if let problem = model.cliProblem {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    }
                    if let version = model.cliVersion { LabeledContent(L10n.text("Version"), value: version).font(.callout) }
                    HStack {
                        Button(saved ? L10n.text("Saved") : (saving ? L10n.text("Saving…") : L10n.text("Save and Check"))) {
                            saving = true
                            saved = false
                            Task {
                                await model.saveCLIPath(pathDraft)
                                pathDraft = model.bwPathOverride
                                saving = false
                                saved = true
                            }
                        }
                        .disabled(saving || model.isBusy || model.isInstalling)
                        Button(L10n.text("Check Again")) { Task { await model.detectAndRetry() } }
                            .disabled(model.isDetecting || saving || model.isInstalling)
                        Spacer()
                        Button(L10n.text("Install Compatible CLI…")) { showInstaller = true }.disabled(saving)
                    }
                    Text(L10n.text("Changing the CLI path locks the vault."))
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label(L10n.text("Vault"), systemImage: "lock.shield") }
                Section {
                    Toggle(L10n.text("Launch VaultSSH at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .disabled(model.isMockMode)
                    if model.launchNeedsApproval {
                        Text(L10n.text("Registered. Allow launch at login in System Settings."))
                            .font(.callout).foregroundStyle(.orange)
                        Button(L10n.text("Open Login Items Settings")) { LaunchAgentManager.openSystemSettings() }
                    }
                } header: { Label(L10n.text("Startup & Security"), systemImage: "power") }
                Section {
                    Picker(L10n.text("Approval Window"), selection: Binding(
                        get: { model.approvalGraceMinutes }, set: { model.setApprovalGraceMinutes($0) })) {
                        ForEach(AppModel.approvalGraceMinutesOptions, id: \.self) { minutes in
                            Text(L10n.text("%ld minutes", minutes)).tag(minutes)
                        }
                    }
                    Text(L10n.text("Temporary approvals apply only to the same caller, parent process and key."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Clear All Approvals"), systemImage: "hand.raised") { model.agent.revokeApprovals() }
                        .disabled(!model.agent.helperRunning)
                    Text(L10n.text("Locking, sleeping, switching users or quitting clears them too."))
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label(L10n.text("SSH Approvals"), systemImage: "key.horizontal") }
                QuickUnlockSettings()
                Section {
                    ConnectionView()
                } header: { Text(L10n.text("SSH Configuration")) }
                Section {
                    LabeledContent("VaultSSH", value: appVersion)
                        .textSelection(.enabled)
                    HStack(spacing: 16) {
                        Link(L10n.text("Project on GitHub"), destination: URL(string: "https://github.com/ruibaby/VaultSSH")!)
                        Link(L10n.text("Troubleshooting"), destination: URL(string: "https://github.com/ruibaby/VaultSSH/blob/main/docs/troubleshooting.md")!)
                        Link(L10n.text("Report an Issue"), destination: URL(string: "https://github.com/ruibaby/VaultSSH/issues/new/choose")!)
                    }
                } header: { Text(L10n.text("About")) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 640, height: 640)
        .onAppear { pathDraft = model.bwPathOverride; model.refreshLaunchStatus() }
        .onChange(of: pathDraft) { _, _ in saved = false }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshLaunchStatus() } }
        .sheet(isPresented: $showInstaller) { InstallerSheet() }
    }

    private var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return L10n.text("Development build")
        }
        return L10n.text("Version %@ (build %@)", version, build)
    }
}

struct InstallerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("Install Compatible CLI"), systemImage: "arrow.down.circle").font(.title2.weight(.semibold))
            Text(L10n.text("Install @bitwarden/cli@%@ using npm without changing your system installation. Requires Node.js and npm.", String(BitwardenCLI.compatibleVersion)))
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("Install Location & Compatibility")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppPaths.tools.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(L10n.text("This version is pinned for compatibility with self-hosted vaults. Later CLI releases may have different server requirements."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
            ScrollView {
                Text(model.installLog.isEmpty ? L10n.text("Sign in to your vault after installation.") : model.installLog)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(minHeight: 190).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if model.isInstalling {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.isInstalling ? L10n.text("Installing…") : L10n.text("Install")) {
                    Task { await model.installCompatibleCLI() }
                }
                .primaryActionStyle().disabled(model.isInstalling)
            }
        }
        .padding(28).frame(width: 580, height: 440)
    }
}
