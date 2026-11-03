import AppKit
import SwiftUI

// Security decisions need a stable surface even over bright windows. Only the
// rounded corners are transparent; the card itself never samples the backdrop.
struct RequestCard: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 15.0, *) {
                content.environment(\.appearsActive, true)
            } else {
                content.environment(\.controlActiveState, .key)
            }
        }
        .foregroundStyle(.primary)
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color(nsColor: .separatorColor)) }
    }
}

struct RequestHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 8)
            Text("VaultSSH").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RequestCaller: View {
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.callerDisplay).font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let pid = request.pid, pid > 0 {
                    Text("PID \(String(pid))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let path = request.executable, !path.isEmpty {
                pathRow(L10n.text("Calling Application"), path)
            } else {
                Text(L10n.text("Unknown caller. Only one-time approval is available."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let path = request.parentExecutable, !path.isEmpty {
                pathRow(L10n.text("Parent Process"), path)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)) }
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(path).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// A non-activating panel must keep its primary action legible even when macOS
// draws native controls with an inactive window appearance.
struct RequestPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Color.white : Color(nsColor: .secondaryLabelColor))
            .background(isEnabled ? Color.blue : Color(nsColor: .quaternaryLabelColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
