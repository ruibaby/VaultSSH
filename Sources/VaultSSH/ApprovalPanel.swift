import AppKit
import Combine
import SwiftUI

/// A quiet, non-activating panel that drops down from the menu bar when an SSH
/// client asks for a signature. It deliberately does not activate the app, so
/// the user's current editing context is not disturbed.
@MainActor
final class ApprovalPanelController: NSObject {
    private var panel: ApprovalPanel?
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        let model = AppModel.shared
        cancellable = Publishers.CombineLatest3(model.agent.$approvals, model.agent.$unlockRequest, model.$showsUnlockPanel)
            .map { approvals, unlock, manual -> PanelState in
                if let request = approvals.first { return .signature(request) }
                if unlock != nil || manual { return .unlock(unlock) }
                return .hidden
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.update(state) }
    }

    private enum PanelState: Equatable {
        case hidden
        case signature(ApprovalRequest)
        case unlock(ApprovalRequest?)
    }

    private func update(_ state: PanelState) {
        let view: AnyView
        switch state {
        case .hidden:
            panel?.orderOut(nil)
            return
        case .unlock(let request): view = AnyView(UnlockPanelView(request: request))
        case .signature(let request):
            view = AnyView(ApprovalView(
                request: request,
                graceLabel: AppModel.approvalGraceLabel,
                onAllow: { AppModel.shared.agent.decideApproval(id: request.id, allow: true, graceSeconds: 300) },
                onOnce: { AppModel.shared.agent.decideApproval(id: request.id, allow: true, graceSeconds: 0) },
                onDeny: { AppModel.shared.agent.decideApproval(id: request.id, allow: false, graceSeconds: 0) }
            ))
        }
        let content = view.environmentObject(AppModel.shared).padding(12)

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 100 || size.height < 100 {
            size = NSSize(width: 384, height: 216)
        }
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = panel ?? makePanel()
        if case .unlock = state { panel.title = L10n.text("Unlock SSH Keys") }
        else { panel.title = L10n.text("SSH Signature Request") }
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    private func makePanel() -> ApprovalPanel {
        let panel = ApprovalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 216),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("SSH Signature Request")
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return .zero }

        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 12
        let y = visible.maxY - size.height - 8
        return NSPoint(x: max(visible.minX + 8, x), y: max(visible.minY + 8, y))
    }
}

private final class ApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ApprovalView: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest
    let graceLabel: String
    let onAllow: () -> Void
    let onOnce: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RequestHeader(title: L10n.text("Allow this SSH signature?"), symbol: "key.horizontal.fill")
            RequestCaller(request: request)
            VStack(alignment: .leading, spacing: 8) {
                Label(request.keyName ?? L10n.text("Unknown key"), systemImage: "key")
                    .font(.system(size: 15, weight: .semibold))
                if let fingerprint = request.fingerprint {
                    Text(fingerprint).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(request.cacheAllowed == true
                 ? L10n.text("Applies only to this caller, parent process and key.")
                 : L10n.text("Unknown processes and script interpreters require one-time approval."))
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(ceil(request.expiration.timeIntervalSince(timeline.date))))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(remaining > 0 ? L10n.text("Auto-deny in %ld seconds", remaining) : L10n.text("Request expired"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        if model.agent.approvals.count > 1 {
                            Text(L10n.text("%ld more requests", model.agent.approvals.count - 1)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(L10n.text("Deny"), action: onDeny).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(L10n.text("Allow for %@", String(graceLabel)), action: onAllow)
                            .disabled(request.cacheAllowed != true)

                        Button(L10n.text("Allow Once"), action: onOnce)
                            .buttonStyle(RequestPrimaryButtonStyle())
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(remaining == 0)
                }
            }
        }
        .modifier(RequestCard())
    }
}
