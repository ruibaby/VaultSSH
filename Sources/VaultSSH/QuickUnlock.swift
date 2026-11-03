import Foundation
import Security
import LocalAuthentication
import CryptoKit
import CommonCrypto

struct SavedSession: Codable, Equatable, Sendable {
    let session: String
    let cliPath: String
    let email: String?
    let server: String?

    func matches(path: String, status: BWStatus) -> Bool {
        (status.status == "locked" || status.status == "unlocked") && email?.isEmpty == false && cliPath == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            && email == status.userEmail && server == status.serverUrl
    }
}

// Persisted PIN material contains no vault session or plaintext PIN/private key.
// The public key seals a fresh session after master-password unlock, without the PIN.
struct PINConfiguration: Codable, Sendable {
    let version: Int
    let salt: Data
    let publicKey: Data
    let wrappedPrivateKey: Data
    let cliPath: String
    let email: String?
    let server: String?

    init(pin: String, session: SavedSession) throws {
        guard PINSession.isValid(pin) else { throw CLIError.failed(L10n.text("Use 6–12 digits for your PIN.")) }
        version = 1
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CLIError.failed(L10n.text("Could not create secure random data."))
        }
        salt = Data(bytes)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKey = privateKey.publicKey.rawRepresentation
        wrappedPrivateKey = try AES.GCM.seal(privateKey.rawRepresentation,
            using: Self.key(pin, salt: salt), authenticating: publicKey).combined!
        cliPath = session.cliPath
        email = session.email
        server = session.server
    }

    func matches(_ session: SavedSession) -> Bool {
        cliPath == session.cliPath && email == session.email && server == session.server
    }

    func validate() throws {
        guard version == 1, salt.count == 32, publicKey.count == 32, wrappedPrivateKey.count == 60 else {
            throw CLIError.failed(L10n.text("Saved PIN data is invalid. Disable PIN and set it again."))
        }
    }

    static func key(_ pin: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        defer { _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result = pin.withCString { password in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count,
                    bytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &derived, derived.count)
            }
        }
        guard result == kCCSuccess else { throw CLIError.failed(L10n.text("Could not protect the PIN session.")) }
        return SymmetricKey(data: derived)
    }
}

// Only ciphertext and PIN-protected key material survive a lock. Session ciphertext
// is never persisted. The five-attempt limit is an app policy, not a hardware boundary.
struct PINSession {
    let configuration: PINConfiguration
    private var ciphertext: Data?
    private let encapsulatedKey: Data
    private static let context = Data("cc.ryanc.VaultSSH.pin-session.v1".utf8)
    private(set) var attemptsRemaining = 5
    var isAvailable: Bool { ciphertext != nil && attemptsRemaining > 0 }

    static func isValid(_ pin: String) -> Bool {
        (6...12).contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    init(pin: String, session: SavedSession) throws {
        try self.init(configuration: PINConfiguration(pin: pin, session: session), session: session)
    }

    init(configuration: PINConfiguration, session: SavedSession) throws {
        try configuration.validate()
        guard configuration.matches(session) else {
            throw CLIError.failed(L10n.text("Your CLI account changed. Unlock with your vault password."))
        }
        self.configuration = configuration
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: configuration.publicKey)
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: Self.context)
        ciphertext = try sender.seal(JSONEncoder().encode(session))
        encapsulatedKey = sender.encapsulatedKey
    }

    mutating func unlock(pin: String) throws -> SavedSession {
        guard let ciphertext, attemptsRemaining > 0 else {
            throw CLIError.failed(L10n.text("PIN is unavailable. Use system authentication or your vault password."))
        }
        attemptsRemaining -= 1
        do {
            guard Self.isValid(pin) else { throw CLIError.failed("") }
            let privateBytes = try AES.GCM.open(AES.GCM.SealedBox(combined: configuration.wrappedPrivateKey),
                using: PINConfiguration.key(pin, salt: configuration.salt), authenticating: configuration.publicKey)
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes)
            guard privateKey.publicKey.rawRepresentation == configuration.publicKey else { throw CLIError.failed("") }
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: Self.context, encapsulatedKey: encapsulatedKey)
            let session = try JSONDecoder().decode(SavedSession.self, from: recipient.open(ciphertext))
            attemptsRemaining = 5
            return session
        } catch {
            if attemptsRemaining == 0 { self.ciphertext = nil }
            throw CLIError.failed(attemptsRemaining == 0
                ? L10n.text("PIN disabled after five failed attempts. Use system authentication or your vault password.")
                : L10n.text("Incorrect PIN. %ld attempts remaining.", attemptsRemaining))
        }
    }
}

// A new LAContext for every attempt prevents reuse of an earlier authentication.
final class SystemUnlockContext: @unchecked Sendable {
    let context = LAContext()
    func cancel() { context.invalidate() }
}

enum QuickUnlockKeychain {
    static let hasAccessEntitlement: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.application-identifier"] as? String != nil
            || (entitlements["keychain-access-groups"] as? [String])?.isEmpty == false
    }()

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "cc.ryanc.VaultSSH.quick-unlock",
         kSecAttrAccount as String: "protected-session-v1",
         kSecUseDataProtectionKeychain as String: true]
    }

    static func save(_ session: SavedSession) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                          .userPresence, &error) else {
            throw CLIError.failed(L10n.text("System-protected quick unlock is unavailable."))
        }
        // Never silently replace this with a legacy or unprotected Keychain item.
        try delete()
        var item = query
        item[kSecAttrAccessControl as String] = access
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    static func load(_ authentication: SystemUnlockContext) throws -> SavedSession {
        defer { authentication.cancel() }
        authentication.context.localizedReason = L10n.text("Unlock your SSH keys in VaultSSH")
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        item[kSecUseAuthenticationContext as String] = authentication.context
        var result: CFTypeRef?
        try check(SecItemCopyMatching(item as CFDictionary, &result))
        guard let data = result as? Data else { throw CLIError.failed(L10n.text("No saved quick-unlock session. Unlock with your vault password.")) }
        return try JSONDecoder().decode(SavedSession.self, from: data)
    }

    static func delete() throws {
        let result = SecItemDelete(query as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecUserCanceled { throw CancellationError() }
        if status == errSecMissingEntitlement {
            throw CLIError.failed(L10n.text("System quick unlock requires an app signed with Keychain access entitlements. PIN remains available."))
        }
        throw CLIError.failed(L10n.text("System quick unlock failed (code %@). Use your vault password.", String(status)))
    }
}
