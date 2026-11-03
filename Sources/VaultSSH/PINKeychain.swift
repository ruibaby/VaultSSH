import Foundation
import Security

// Deliberately uses the macOS login keychain, not the system-authenticated
// quick-unlock item. Only PIN-protected key material is stored here, never a
// vault session. The default item ACL trusts the creating application.
struct PINKeychain: Sendable {
    let service: String
    static let shared = PINKeychain(service: "cc.ryanc.VaultSSH.pin")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "pin-configuration-v1",
         kSecUseDataProtectionKeychain as String: false,
         kSecAttrSynchronizable as String: false]
    }

    func save(_ configuration: PINConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        let attributes = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(result) }
    }

    func load() throws -> PINConfiguration? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, data.count <= 16_384 else {
            throw CLIError.failed(L10n.text("Saved PIN data is invalid. Disable PIN and set it again."))
        }
        let configuration = try JSONDecoder().decode(PINConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CLIError.failed(L10n.text("Could not access the saved PIN in Keychain (code %@).", String(status)))
        }
    }
}
