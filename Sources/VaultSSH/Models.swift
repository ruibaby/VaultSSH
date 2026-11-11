import Foundation

struct KeyInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let fingerprint: String
    let publicKey: String
}

struct AgentStatus: Codable, Equatable {
    var state: String = "stopped"
    var pid: Int?
    var socket: String?
    var keys: [KeyInfo]?
    var error: String?
    var updatedAt: String?
    var warnings: [String]?
    var phase: String?

    static let stopped = AgentStatus(state: "stopped")
}

struct AgentEvent: Codable, Identifiable, Hashable {
    let time: String
    let type: String
    let pid: Int?
    let process: String?
    let executable: String?
    let parentPid: Int?
    let parentProcess: String?
    let keyName: String?
    let fingerprint: String?
    let result: String?
    let detail: String?
    var reason: String? = nil

    var id: String {
        [time, type, String(pid ?? 0), keyName ?? "", detail ?? ""].joined(separator: "|")
    }

    var timeDisplay: String {
        guard let date = Self.iso.date(from: time) ?? Self.isoNoFraction.date(from: time) else {
            let t = time.split(separator: "T").last ?? ""
            return String(t.prefix(8))
        }
        return Self.clock.string(from: date)
    }

    var dateDisplay: String {
        guard let date = Self.iso.date(from: time) ?? Self.isoNoFraction.date(from: time) else { return time }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    var actionLabel: String {
        switch type {
        case "sign": return L10n.text("Sign")
        case "list": return L10n.text("List Keys")
        case "ready": return L10n.text("Ready")
        case "error": return L10n.text("Error")
        case "warning": return L10n.text("Warning")
        default: return L10n.text("Other Activity")
        }
    }

    var isError: Bool { result == "error" || result == "denied" }

    var processDisplay: String {
        if type == "ready" { return "—" }
        guard let process, !process.isEmpty else { return L10n.text("Unknown") }
        return process
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct BWStatus: Codable {
    let status: String?
    let userEmail: String?
    let serverUrl: String?
    let lastSync: String?
}

struct ApprovalRequest: Codable, Identifiable, Equatable, Sendable {
    var cacheAllowed: Bool? = nil
    let id: String
    let created: String?
    let expiresAt: String?
    let pid: Int?
    let process: String?
    let executable: String?
    let parentPid: Int?
    let parentProcess: String?
    let parentExecutable: String?
    let keyName: String?
    let fingerprint: String?

    var callerDisplay: String {
        let name = process.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Unknown process")
        guard let parent = parentProcess, !parent.isEmpty, parent != name else {
            return name
        }
        return "\(name) ← \(parent)"
    }
}

struct ApprovalDecision: Codable, Sendable {
    let id: String
    let allow: Bool
    let graceSeconds: Int
}

struct ControlEvent: Decodable, Sendable {
    let type: String
    let id: String?
    let request: ApprovalRequest?
    let status: AgentStatus?
    let event: AgentEvent?
    let keys: [KeyInfo]?
    let graceSeconds: Int?
}

struct ControlCommand: Encodable {
    let type: String
    var session: String? = nil
    var id: String? = nil
    var decision: ApprovalDecision? = nil
    var keyOrder: [String]? = nil
    var graceSeconds: Int? = nil
}

extension ApprovalRequest {
    var expiration: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let expiresAt, let date = formatter.date(from: expiresAt) { return date }
        if let created, let date = formatter.date(from: created) { return date.addingTimeInterval(60) }
        return .distantPast
    }
}

extension AgentEvent {
    var resultLabel: String {
        switch result {
        case "denied":
            if reason == "timeout" || reason == "expired" { return L10n.text("Timed Out") }
            if reason == "revoked" { return L10n.text("Revoked") }
            // Older logs stored only Chinese descriptions, without reason codes.
            if reason == nil, detail?.contains("超时") == true { return L10n.text("Timed Out") }
            if reason == nil, detail?.contains("撤销") == true { return L10n.text("Revoked") }
            return L10n.text("Denied")
        case "error": return L10n.text("Failed")
        case "warning": return L10n.text("Needs Review")
        case "ok": return L10n.text("Succeeded")
        default: return L10n.text("Unknown Result")
        }
    }
    var diagnosticText: String {
        L10n.text("Time: %@\nAction: %@\nResult: %@\nProcess: %@ (PID %@)\nPath: %@\nParent: %@ (PID %@)\nKey: %@\nFingerprint: %@\nDetails: %@", String(time), String(actionLabel), String(resultLabel), String(processDisplay), String(pid ?? 0), String(executable ?? "—"), String(parentProcess ?? "—"), String(parentPid ?? 0), String(keyName ?? "—"), String(fingerprint ?? "—"), String(detail ?? "—"))
    }
}
