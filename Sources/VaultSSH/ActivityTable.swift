import AppKit
import SwiftUI

// Native reusable cells avoid retaining a SwiftUI view graph for every visited cell.
struct ActivityTable: NSViewRepresentable {
    let events: [AgentEvent]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        for (id, title, width, min, max) in [
            ("time", "Time", 68.0, 62.0, 80.0),
            ("action", "Action", 75.0, 65.0, 90.0),
            ("caller", "Caller", 140.0, 100.0, 1000.0),
            ("key", "Keys", 130.0, 80.0, 1000.0),
            ("result", "Result", 80.0, 74.0, 100.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = L10n.text(title)
            column.minWidth = min
            column.maxWidth = max
            column.width = width
            table.addTableColumn(column)
        }
        table.setAccessibilityLabel(L10n.text("Activity"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.selection = $selection
        context.coordinator.update(table, events: events, selectedID: selection)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: Binding<String?>
        private var events: [AgentEvent] = []
        private var updating = false

        init(selection: Binding<String?>) { self.selection = selection }

        func update(_ table: NSTableView, events: [AgentEvent], selectedID: String?) {
            // Reloading can emit selection notifications synchronously. Only user
            // selection changes should write back into SwiftUI during this update.
            updating = true
            defer { updating = false }
            if self.events != events {
                self.events = events
                table.reloadData()
            }
            let row = selectedID.flatMap { id in events.firstIndex { $0.id == id } } ?? -1
            if table.selectedRow != row {
                table.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : IndexSet(), byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { events.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            selection.wrappedValue = events.indices.contains(table.selectedRow) ? events[table.selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, events.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ActivityTableCell
                ?? ActivityTableCell(identifier: id)
            cell.configure(events[row])
            return cell
        }
    }
}

private final class ActivityTableCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addSubview(label)
        textField = label
        var leading = leadingAnchor
        var spacing: CGFloat = 0
        if identifier.rawValue == "result" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14)
            ])
            leading = icon.trailingAnchor
            spacing = 4
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: spacing),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ event: AgentEvent) {
        guard let label = textField else { return }
        label.textColor = .labelColor
        toolTip = nil
        switch identifier?.rawValue {
        case "time":
            label.stringValue = event.timeDisplay
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            toolTip = event.time
        case "action": label.stringValue = event.actionLabel
        case "caller":
            let text = NSMutableAttributedString(string: event.processDisplay, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            ])
            if let parent = event.parentProcess, !parent.isEmpty {
                text.append(NSAttributedString(string: " ← \(parent)", attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            label.attributedStringValue = text
        case "key":
            label.stringValue = event.keyName ?? "—"
            toolTip = event.keyName ?? L10n.text("No associated key")
        case "result":
            label.stringValue = event.resultLabel
            let warning = event.result == "warning"
            let color: NSColor = event.isError ? .systemRed : (warning ? .systemOrange : .secondaryLabelColor)
            label.textColor = color
            imageView?.contentTintColor = color
            imageView?.image = NSImage(systemSymbolName: event.isError ? "xmark.circle" : (warning ? "exclamationmark.circle" : "checkmark.circle"), accessibilityDescription: nil)
            toolTip = event.detail ?? event.resultLabel
        default: break
        }
    }
}
