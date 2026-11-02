import Foundation
import Security

enum Keychain {
    private static let service = "cc.ryanc.VaultSSH"
    private static let account = "bw-session"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            try check(SecItemAdd(item as CFDictionary, nil), operation: L10n.text("save session"))
        } else {
            try check(status, operation: L10n.text("update session"))
        }
    }

    static func load() throws -> String? {
        var itemQuery = query
        itemQuery[kSecReturnData as String] = true
        itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(itemQuery as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: L10n.text("read session"))
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CLIError.failed(L10n.text("Invalid Keychain session data. Unlock again."))
        }
        return value
    }

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
