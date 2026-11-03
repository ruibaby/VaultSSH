import SwiftUI

struct UnlockControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var secret = ""
    @State private var usePIN = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.systemUnlockEnabled {
                Button(L10n.text("Touch ID or Mac Password"), systemImage: "touchid") {
                    secret = ""
                    Task { await model.unlockWithSystem() }
                }
                .primaryActionStyle().disabled(model.isBusy)
            }
            if model.pinEnabled {
                Picker(L10n.text("Unlock Method"), selection: $usePIN) {
                    Text(L10n.text("PIN")).tag(true)
                    Text(L10n.text("Vault Password")).tag(false)
                }
                .pickerStyle(.segmented).disabled(model.isUnlocking)
            }
            SecureField(usePIN ? L10n.text("PIN") : L10n.text("Bitwarden master password"), text: $secret)
                .textFieldStyle(.roundedBorder).disabled(model.isUnlocking)
                .onSubmit(unlock)
            HStack {
                if model.isUnlocking { ProgressView().controlSize(.small) }
                Button(model.isUnlocking ? L10n.text("Unlocking…") : L10n.text("Unlock"), action: unlock)
                    .primaryActionStyle().disabled(secret.isEmpty || model.isBusy)
                if model.isUnlocking {
                    Button(L10n.text("Cancel")) { secret = ""; model.cancelUnlock() }
                }
            }
            if model.isUnlocking {
                Text(model.unlockProgressTitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { usePIN = model.pinEnabled }
        .onChange(of: usePIN) { _, _ in secret = "" }
        .onChange(of: model.pinEnabled) { _, enabled in if !enabled { usePIN = false; secret = "" } }
        .onDisappear { secret = "" }
    }

    private func unlock() {
        guard !secret.isEmpty, !model.isBusy else { return }
        let value = secret
        let pin = usePIN
        secret = ""
        Task {
            if pin { await model.unlockWithPIN(value) }
            else { await model.unlock(password: value) }
        }
    }
}

struct UnlockPanelView: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Unlock SSH Keys"), systemImage: "lock.open").font(.headline)
            if let request {
                Text(request.callerDisplay).font(.title3.weight(.semibold))
                if let path = request.executable { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                Text(L10n.text("SSH is waiting. Unlocking does not approve a signature."))
                    .font(.callout).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(L10n.text("Request expires in %ld seconds", max(0, Int(ceil(request.expiration.timeIntervalSince(timeline.date))))))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.cliReady { UnlockControls() }
            else { Text(L10n.text("Set up and sign in to the CLI in Settings first.")) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text(L10n.text("Unlock without opening the main window.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Cancel")) { model.cancelUnlock() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

struct QuickUnlockSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var pin = ""
    @State private var confirmation = ""

    var body: some View {
        Section {
            Toggle(L10n.text("Touch ID or Mac Password"), isOn: Binding(
                get: { model.systemUnlockEnabled }, set: { enabled in
                    if enabled { Task { await model.enableSystemUnlock() } }
                    else { model.disableSystemUnlock() }
                }))
                .disabled(model.isBusy || (!model.hasSession && !model.systemUnlockEnabled) || model.isMockMode || (!QuickUnlockKeychain.hasAccessEntitlement && !model.systemUnlockEnabled))
            if !QuickUnlockKeychain.hasAccessEntitlement {
                Text(L10n.text("System quick unlock is unavailable in this build. You can use PIN instead."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("Optional: save the vault session in Keychain. Each use requires system authentication; your vault password is never saved."))
                .font(.caption).foregroundStyle(.secondary)
            if model.pinEnabled {
                LabeledContent(L10n.text("PIN"), value: L10n.text("Enabled for this app session"))
                Button(L10n.text("Disable PIN")) { model.disablePIN() }.disabled(model.isBusy)
            } else {
                SecureField(L10n.text("New PIN (6–12 digits)"), text: $pin)
                SecureField(L10n.text("Confirm PIN"), text: $confirmation)
                Button(L10n.text("Enable PIN")) {
                    model.setPIN(pin, confirmation: confirmation)
                    pin = ""; confirmation = ""
                }
                .disabled(!model.hasSession || model.isBusy || pin.isEmpty || confirmation.isEmpty)
            }
            Text(L10n.text("Unlock your vault first to enable quick unlock. PIN works until you quit or unlock with your vault password again. Five incorrect attempts disable it."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("Lock After Inactivity"), selection: Binding(get: { model.idleLockMinutes }, set: model.setIdleLockMinutes)) {
                Text(L10n.text("Never")).tag(0)
                ForEach([5, 15, 30, 60], id: \.self) { minutes in Text(L10n.text("%ld minutes", minutes)).tag(minutes) }
            }
            Text(L10n.text("Sleep, screen lock and user switching still lock your keys. Waking does not unlock them."))
                .font(.caption).foregroundStyle(.secondary)
        } header: { Label(L10n.text("Quick Unlock & Locking"), systemImage: "lock.shield") }
        .onDisappear { pin = ""; confirmation = "" }
    }
}
