import Foundation
import Security

enum KeychainError: LocalizedError {
    case unableToSave(OSStatus)
    case unableToDelete(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToSave(let status):
            return "The key couldn't be saved to the Keychain (error \(status))."
        case .unableToDelete(let status):
            return "The key couldn't be removed from the Keychain (error \(status))."
        }
    }
}

/// Keychain-backed storage for the OpenRouter API key.
///
/// The key is a bearer credential for a billable account, so it goes here rather
/// than `UserDefaults` — and it is never logged, never included in error
/// messages, and never written into the SwiftData store.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means it is readable only while
/// the device is unlocked and is excluded from backups and device-to-device
/// transfer. Restoring onto a new phone deliberately does not carry the key over.
enum KeychainStore {
    private static let service = "com.michaelthornton.VoiceRecorder"
    private static let account = "openrouter-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Writes the key, throwing if the Keychain refuses.
    ///
    /// This throws rather than failing quietly because the in-memory copy would
    /// otherwise keep working for the rest of the session and the key would
    /// simply be missing on next launch — a confusing failure that looks like
    /// the app forgot a key the user is certain they entered.
    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unableToSave(errSecParam)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(
                baseQuery.merging(attributes) { $1 } as CFDictionary,
                nil
            )
            guard addStatus == errSecSuccess else {
                throw KeychainError.unableToSave(addStatus)
            }
        default:
            throw KeychainError.unableToSave(updateStatus)
        }
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }

        return value
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Nothing stored is the outcome the caller wanted, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete(status)
        }
    }

    static var hasKey: Bool { load() != nil }
}
