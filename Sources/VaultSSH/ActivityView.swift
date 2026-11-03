import SwiftUI

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all, sign, list, error
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.text("All")
        case .sign: return L10n.text("Sign")
        case .list: return L10n.text("List")
        case .error: return L10n.text("Issues")
        }
    }
    func matches(_ event: AgentEvent) -> Bool {
        switch self {
        case .all: return true
        case .sign: return event.type == "sign"
        case .list: return event.type == "list"
        case .error: return event.isError || event.type == "warning" || event.type == "error"
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: ActivityFilter = .all
    @State private var search = ""
    @State private var selection: String?
    @State private var showDetails = false

    private var filtered: [AgentEvent] {
        model.agent.events.filter {
            filter.matches($0) && (search.isEmpty || $0.diagnosticText.localizedCaseInsensitiveContains(search))
        }.reversed()
    }
    private var selectedEvent: AgentEvent? { filtered.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Activity")).font(.title2.weight(.semibold))
                Spacer()
                Text(L10n.text("%ld events", filtered.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { showDetails.toggle() } label: { Label(L10n.text("Activity Details"), systemImage: "rectangle.bottomthird.inset.filled") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(selectedEvent == nil).help(L10n.text("Activity Details"))
            }
            .padding(20)
            HStack(spacing: 12) {
                activityPicker.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                TextField(L10n.text("Search callers, keys, or details"), text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty && filter == .all ? L10n.text("No activity yet") : L10n.text("No matching activity"), systemImage: "clock.arrow.circlepath")
                } description: {
                    if !search.isEmpty || filter != .all {
                        Text(L10n.text("Try another filter or search term."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn(L10n.text("Time")) { event in
                        Text(event.timeDisplay).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).help(event.time)
                    }.width(min: 62, ideal: 68, max: 80)
                    TableColumn(L10n.text("Action")) { event in
                        Text(event.actionLabel).font(.callout)
                    }.width(min: 65, ideal: 75, max: 90)
                    TableColumn(L10n.text("Caller")) { event in
                        HStack(spacing: 5) {
                            Text(event.processDisplay).font(.callout.weight(.medium))
                            if let parent = event.parentProcess, !parent.isEmpty {
                                Text("← \(parent)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.lineLimit(1)
                    }.width(min: 100, ideal: 140)
                    TableColumn(L10n.text("Keys")) { event in
                        Text(event.keyName ?? "—").font(.callout).lineLimit(1).help(event.keyName ?? L10n.text("No associated key"))
                    }.width(min: 80, ideal: 130)
                    TableColumn(L10n.text("Result")) { event in
                        Label(event.resultLabel, systemImage: event.isError ? "xmark.circle" : (event.result == "warning" ? "exclamationmark.circle" : "checkmark.circle"))
                            .font(.caption).foregroundStyle(event.isError ? .red : (event.result == "warning" ? .orange : .secondary))
                            .help(event.detail ?? event.resultLabel)
                    }.width(min: 74, ideal: 80, max: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .onChange(of: selection) { _, value in showDetails = value != nil }
        .onChange(of: filter) { _, _ in selection = nil; showDetails = false }
        .onChange(of: search) { _, _ in selection = nil; showDetails = false }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showDetails, let event = selectedEvent {
                VStack(spacing: 0) {
                    Divider()
                    EventDetailView(event: event).frame(height: 240)
                }
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var activityPicker: some View {
        let picker = Picker(L10n.text("Activity Type"), selection: $filter) {
            ForEach(ActivityFilter.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()

        if #available(macOS 27.0, *) {
            picker.pickerStyle(.tabs).controlSize(.large)
        } else {
            picker.pickerStyle(.segmented)
        }
    }
}

private struct EventDetailView: View {
    let event: AgentEvent
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L10n.text("Activity Details")).font(.headline)
                    Spacer()
                    Text(event.resultLabel).font(.caption.weight(.medium)).foregroundStyle(event.isError ? .red : .secondary)
                }
                DetailValue(title: L10n.text("Details"), value: event.detail.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("The operation completed with no additional details."))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                    DetailValue(title: L10n.text("Time"), value: event.dateDisplay)
                    DetailValue(title: L10n.text("Action"), value: event.actionLabel)
                    DetailValue(title: L10n.text("Calling Process"), value: "\(event.processDisplay) · PID \(event.pid ?? 0)")
                    if let parent = event.parentProcess { DetailValue(title: L10n.text("Parent Process"), value: "\(parent) · PID \(event.parentPid ?? 0)") }
                    if let name = event.keyName { DetailValue(title: L10n.text("Keys"), value: name) }
                    if let fingerprint = event.fingerprint { DetailValue(title: L10n.text("Fingerprint"), value: fingerprint, monospaced: true) }
                }
                if let executable = event.executable { DetailValue(title: L10n.text("Executable"), value: executable, monospaced: true) }

                Divider()
                CopyButton(title: L10n.text("Copy Diagnostics"), value: event.diagnosticText, compact: true)
            }.padding(20)
        }
    }
}
