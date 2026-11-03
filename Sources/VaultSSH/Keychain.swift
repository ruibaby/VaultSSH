import Foundation
import Security

enum Keychain {
    private static let service = "cc.ryanc.VaultSSH"
    private static let account = "bw-session"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // Migration cleanup only. New sessions are never persisted.
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: L10n.text("delete session")) }
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? L10n.text("Error code %@", String(status))
        throw CLIError.failed(L10n.text("Could not %@ in Keychain: %@", String(operation), String(message)))
    }
}
