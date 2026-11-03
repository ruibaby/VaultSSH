import Foundation

// Small boundary for operations that touch credentials or external processes.
// Tests can exercise the real model without reading the user's Keychain.
struct AppServices {
    var deleteSession: () throws -> Void = { try Keychain.delete() }
    var resolveCLI: (String) async -> (path: String, version: String)? = { override in
        await Task.detached { BitwardenCLI.resolve(override: override) }.value
    }
    var status: (String) async throws -> BWStatus = { path in
        try await Task.detached { try BitwardenCLI(path: path).status() }.value
    }
    var unlock: (String, String) async throws -> String = { path, password in
        let cancellation = CLIProcessCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try BitwardenCLI(path: path).unlock(password: password, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }
}
