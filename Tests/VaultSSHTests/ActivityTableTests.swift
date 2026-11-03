import AppKit
import SwiftUI
import XCTest
@testable import VaultSSH

@MainActor
final class ActivityTableTests: XCTestCase {
    private func event(_ index: Int, result: String = "ok") -> AgentEvent {
        AgentEvent(time: "2026-11-03T12:00:00Z", type: "sign", pid: index, process: "ssh",
                   executable: nil, parentPid: nil, parentProcess: nil, keyName: "Key \(index)",
                   fingerprint: nil, result: result, detail: nil)
    }

    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(child) { return table }
        }
        return nil
    }

    private func settle(_ view: NSView) async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
    }

    func testSelectionTracksIdentityAcrossPrependingAndFiltering() async throws {
        _ = NSApplication.shared
        let first = event(1), second = event(2), newest = event(3)
        var selected: String? = second.id
        var writes = 0
        let binding = Binding<String?>(get: { selected }, set: { selected = $0; writes += 1 })
        let host = NSHostingView(rootView: ActivityTable(events: [second, first], selection: binding))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 300)
        await settle(host)
        let table = try XCTUnwrap(findTable(host))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 0)

        host.rootView = ActivityTable(events: [newest, second, first], selection: binding)
        await settle(host)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(selected, second.id)
        XCTAssertEqual(writes, 0, "Reloads must not write SwiftUI state during updateNSView")

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(selected, first.id)
        XCTAssertEqual(writes, 1)

        selected = nil
        host.rootView = ActivityTable(events: [newest], selection: binding)
        await settle(host)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertEqual(writes, 1)

        host.rootView = ActivityTable(events: [], selection: binding)
        await settle(host)
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testReusedResultCellUpdatesTextColorAndTooltip() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ActivityTable(events: [event(1, result: "denied")], selection: .constant(nil)))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 300)
        await settle(host)
        let table = try XCTUnwrap(findTable(host))
        let column = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "result" })
        let denied = try XCTUnwrap(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(denied.textField?.stringValue, L10n.text("Denied"))
        XCTAssertEqual(denied.textField?.textColor, .systemRed)

        host.rootView = ActivityTable(events: [event(1)], selection: .constant(nil))
        await settle(host)
        let succeeded = try XCTUnwrap(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(succeeded.textField?.stringValue, L10n.text("Succeeded"))
        XCTAssertEqual(succeeded.textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(succeeded.imageView?.contentTintColor, .secondaryLabelColor)
        XCTAssertEqual(succeeded.toolTip, L10n.text("Succeeded"))
    }
}
