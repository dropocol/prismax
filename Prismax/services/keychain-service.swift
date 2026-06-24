import Foundation
import Security

/// Thin wrapper around the macOS Keychain (Security framework) for storing
/// environment-variable values. Values are never written to disk in plaintext.
///
/// Each value is stored as a generic password item under the service
/// `com.prismax.env` with a unique account identifier per (project, env, key).
enum KeychainService {
    static let service = "com.prismax.env"

    enum Error: Swift.Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversion

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): "Keychain error (status \(s))."
            case .dataConversion: "Could not convert value to data."
            }
        }
    }

    // MARK: Read

    static func get(account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account) as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw Error.dataConversion
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unexpectedStatus(status)
        }
    }

    /// Convenience: returns the masked form for UI display (e.g. "••••••••7890").
    static func maskedValue(account: String) -> String {
        guard let value = try? get(account: account), !value.isEmpty else { return "" }
        if value.count <= 8 { return String(repeating: "•", count: value.count) }
        let suffix = value.suffix(4)
        return String(repeating: "•", count: 8) + suffix
    }

    // MARK: Write

    static func set(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw Error.dataConversion }

        // Delete any existing item first so upsert is idempotent.
        try? delete(account: account)

        var attributes: [String: Any] = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrIsInvisible as String] = true

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
    }

    // MARK: Delete

    @discardableResult
    static func delete(account: String) throws -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw Error.unexpectedStatus(status)
        }
    }

    // MARK: Private

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }
}
