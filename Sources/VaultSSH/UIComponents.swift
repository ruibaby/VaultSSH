import SwiftUI
import AppKit

struct CopyButton: View {
    let title: String
    let value: String
    var compact = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Label(copied ? L10n.text("Copied") : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .font(compact ? .caption : .body)
        .help(title)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L10n.text("Dismiss message")).accessibilityLabel(L10n.text("Dismiss message"))
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension View {
    @ViewBuilder func primaryActionStyle() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent) }
    }
}

struct DetailValue: View {
    let title: String
    let value: String
    var monospaced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
