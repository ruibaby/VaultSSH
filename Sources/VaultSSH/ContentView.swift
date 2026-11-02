import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConnection = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if model.errorMessage != nil { ErrorBanner().padding([.horizontal, .top], 16) }
                if let request = model.pendingApproval {
                    PendingApprovalBanner(request: request).padding([.horizontal, .top], 16)
                }
                ActivityView()
            }
        }
        .navigationTitle("VaultSSH")
        .navigationSubtitle(L10n.text("Your keys. Your approval."))
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.hasSession {
                    Button { Task { await model.refreshKeys() } } label: {
                        Label(L10n.text("Refresh Keys"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy).help(L10n.text("Reload keys from your vault"))
                }
                if model.hasSession || model.isBusy {
                    Button { model.lock() } label: { Label(L10n.text("Lock"), systemImage: "lock") }
                        .help(L10n.text("Lock the vault and stop all signing"))
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
                SettingsLink { Label(L10n.text("Settings"), systemImage: "gearshape") }.help(L10n.text("Settings"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.agent.status.state == "ready" ? "checkmark.shield" : "lock.shield")
                    .foregroundStyle(.secondary)
                Text(model.agent.notice ?? (model.agent.status.state == "ready" ? L10n.text("You'll be asked before signing") : L10n.text("Unlock to use your SSH keys")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L10n.text("Connect SSH"), systemImage: "terminal") { showConnection = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showConnection) { ConnectionView().padding(24).frame(width: 490) }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
        .frame(minWidth: 900, minHeight: 580)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedKey: KeyInfo?
    private var ready: Bool { model.agent.status.state == "ready" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: ready ? "lock.open" : "lock")
                            .font(.system(size: 23, weight: .medium)).foregroundStyle(ready ? .green : .secondary)
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.stateTitle).font(.title3.weight(.semibold))
                            Text(ready ? L10n.text("%ld keys available", model.agent.keys.count) : L10n.text("Private keys are available only while unlocked"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.isBusy { ProgressView().controlSize(.small) }
                    }
                    if let email = model.bwStatus?.userEmail {
                        Label(email, systemImage: "person.crop.circle")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(email)
                    }
                    if let error = model.agent.status.error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                AccessView()
                if let warnings = model.agent.status.warnings, !warnings.isEmpty {
                    DisclosureGroup {
                        ForEach(warnings, id: \.self) { warning in
                            Text(warning).font(.caption).textSelection(.enabled).padding(.vertical, 4)
                        }
                    } label: {
                        Label(L10n.text("%ld loading warnings", warnings.count), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("Keys")).font(.headline)
                        Spacer()
                        Text("\(model.agent.keys.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if model.agent.keys.isEmpty {
                        Text(model.isBusy ? L10n.text("Reading your vault…") : L10n.text("Your keys will appear here after unlocking."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.agent.keys.count > 1 {
                        Text(L10n.text("Keys are offered in this order. Use a key's menu to reorder."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.agent.keys.enumerated()), id: \.element.id) { index, key in
                        HStack(spacing: 8) {
                            Button { selectedKey = key } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "key.horizontal").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(key.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                            if index == 0 && model.agent.keys.count > 1 {
                                                Text(L10n.text("Preferred")).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(key.fingerprint).font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 7).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(L10n.text("View the public key and fingerprint for %@", String(key.name)))
                            if model.agent.keys.count > 1 {
                                Menu {
                                    Button(L10n.text("Use First"), systemImage: "arrow.up.to.line") { model.agent.moveKey(key, to: 0) }
                                        .disabled(index == 0)
                                    Divider()
                                    Button(L10n.text("Move Up"), systemImage: "arrow.up") { model.agent.moveKey(key, to: index - 1) }
                                        .disabled(index == 0)
                                    Button(L10n.text("Move Down"), systemImage: "arrow.down") { model.agent.moveKey(key, to: index + 1) }
                                        .disabled(index == model.agent.keys.count - 1)
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .disabled(!ready || model.isBusy)
                                .accessibilityLabel(L10n.text("Reorder %@", String(key.name)))
                                .help(L10n.text("Change the SSH key order for %@ on this Mac only", String(key.name)))
                            }
                        }
                    }
                }
                if ready {
                    Button(L10n.text("Revoke Temporary Approvals"), systemImage: "hand.raised") { model.agent.revokeApprovals() }
                        .buttonStyle(.borderless).font(.callout)
                        .help(L10n.text("Cancel all five-minute approvals and pending requests"))
                }
            }
            .padding(20)
        }
        .sheet(item: $selectedKey) { key in KeyDetailView(key: key) }
    }
}

private struct KeyDetailView: View {
    let key: KeyInfo
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(key.name, systemImage: "key.horizontal").font(.title2.weight(.semibold))
            DetailValue(title: L10n.text("Fingerprint"), value: key.fingerprint, monospaced: true)
            DetailValue(title: L10n.text("Public Key"), value: key.publicKey, monospaced: true)
            HStack {
                CopyButton(title: L10n.text("Copy Public Key"), value: key.publicKey)
                CopyButton(title: L10n.text("Copy Fingerprint"), value: key.fingerprint)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(28).frame(width: 530)
    }
}

private struct PendingApprovalBanner: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest
    @State private var showRequest = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Signature Approval Needed")).font(.callout.weight(.semibold))
                Text("\(request.callerDisplay) · \(request.keyName ?? L10n.text("Unknown key"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(L10n.text("Review Request")) { showRequest = true }.primaryActionStyle()
        }
        .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showRequest) {
            ApprovalView(request: request, graceLabel: AppModel.approvalGraceLabel,
                onAllow: { decide(true, 300) }, onOnce: { decide(true, 0) }, onDeny: { decide(false, 0) })
                .environmentObject(model).padding(12)
        }
    }
    private func decide(_ allow: Bool, _ seconds: Int) {
        model.agent.decideApproval(id: request.id, allow: allow, graceSeconds: seconds)
        showRequest = false
    }
}
