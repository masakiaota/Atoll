/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Security

enum ExtensionRPCTokenStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll").extension-rpc"
    }
    private static let tokenByteCount = 32

    static func readOrCreateToken(for bundleIdentifier: String) throws -> String {
        if let token = try readToken(for: bundleIdentifier) {
            return token
        }

        let token = try generateToken()
        let status = SecItemAdd(addQuery(for: token, bundleIdentifier: bundleIdentifier) as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return token
        case errSecDuplicateItem:
            guard let existingToken = try readToken(for: bundleIdentifier) else {
                throw ExtensionRPCTokenStoreError.keychainFailure(operation: "read", status: status)
            }
            return existingToken
        default:
            throw ExtensionRPCTokenStoreError.keychainFailure(operation: "create", status: status)
        }
    }

    static func regenerateToken(for bundleIdentifier: String) throws -> String {
        let token = try generateToken()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery(for: bundleIdentifier) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return token
        case errSecItemNotFound:
            let addStatus = SecItemAdd(
                addQuery(for: token, bundleIdentifier: bundleIdentifier) as CFDictionary,
                nil
            )
            guard addStatus == errSecSuccess else {
                throw ExtensionRPCTokenStoreError.keychainFailure(operation: "create", status: addStatus)
            }
            return token
        default:
            throw ExtensionRPCTokenStoreError.keychainFailure(operation: "update", status: status)
        }
    }

    static func deleteToken(for bundleIdentifier: String) throws {
        let status = SecItemDelete(baseQuery(for: bundleIdentifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionRPCTokenStoreError.keychainFailure(operation: "delete", status: status)
        }
    }

    private static func baseQuery(for bundleIdentifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleIdentifier,
            // The Data Protection keychain scopes this item to Atoll's
            // code-signing access group and ignores attacker-seeded legacy
            // keychain items with the same public service/account names.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func addQuery(for token: String, bundleIdentifier: String) -> [String: Any] {
        var query = baseQuery(for: bundleIdentifier)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    private static func readToken(for bundleIdentifier: String) throws -> String? {
        var query = baseQuery(for: bundleIdentifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  isValidToken(token) else {
                throw ExtensionRPCTokenStoreError.invalidStoredToken
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw ExtensionRPCTokenStoreError.keychainFailure(operation: "read", status: status)
        }
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ExtensionRPCTokenStoreError.randomGenerationFailure(status: status)
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidToken(_ token: String) -> Bool {
        guard token.utf8.count == tokenByteCount * 2 else { return false }
        return token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

private enum ExtensionRPCTokenStoreError: LocalizedError {
    case invalidStoredToken
    case keychainFailure(operation: String, status: OSStatus)
    case randomGenerationFailure(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredToken:
            return "The stored RPC authentication token is invalid."
        case let .keychainFailure(operation, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not \(operation) the RPC authentication token in Keychain: \(message)"
        case let .randomGenerationFailure(status):
            return "Could not securely generate the RPC authentication token (OSStatus \(status))."
        }
    }
}
