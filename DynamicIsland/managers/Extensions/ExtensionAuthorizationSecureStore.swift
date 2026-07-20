/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import Security

/// Keychain-backed authority for extension grants.
///
/// Preferences remain useful for UI metadata, but another unsandboxed process
/// running as the same user can edit them. Authorization decisions therefore
/// require a matching record in Keychain, whose ACL is tied to Atoll's code.
enum ExtensionAuthorizationSecureStore {
    struct Record: Codable, Hashable {
        let bundleIdentifier: String
        var appName: String
        var status: ExtensionAuthorizationStatus
        var allowedScopes: Set<ExtensionPermissionScope>
        var trustedXPCCodeSigningRequirement: String?
        var trustedXPCApplicationPath: String?
        var isRemoved: Bool

        var isAuthorized: Bool {
            status == .authorized && !isRemoved
        }
    }

    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll").extension-authorization"
    }

    static func readRecord(for bundleIdentifier: String) throws -> Record? {
        var query = baseQuery(for: bundleIdentifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw ExtensionAuthorizationSecureStoreError.invalidStoredRecord(bundleIdentifier)
            }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: data)
            } catch {
                throw ExtensionAuthorizationSecureStoreError.invalidStoredRecord(bundleIdentifier)
            }
            guard record.bundleIdentifier == bundleIdentifier,
                  record.allowedScopes.isSubset(of: Set(ExtensionPermissionScope.allCases)) else {
                throw ExtensionAuthorizationSecureStoreError.invalidStoredRecord(bundleIdentifier)
            }
            return record
        case errSecItemNotFound:
            return nil
        default:
            throw ExtensionAuthorizationSecureStoreError.keychainFailure(operation: "read", status: status)
        }
    }

    static func save(_ record: Record) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw ExtensionAuthorizationSecureStoreError.encodingFailure
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(for: record.bundleIdentifier) as CFDictionary,
            attributes as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(for: record.bundleIdentifier)
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ExtensionAuthorizationSecureStoreError.keychainFailure(operation: "create", status: addStatus)
            }
        default:
            throw ExtensionAuthorizationSecureStoreError.keychainFailure(operation: "update", status: updateStatus)
        }
    }

    private static func baseQuery(for bundleIdentifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleIdentifier,
            // Use the app's code-signing-derived default access group. Legacy
            // macOS keychain items are intentionally invisible here so another
            // same-user process cannot pre-seed a record that Atoll will trust.
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

private enum ExtensionAuthorizationSecureStoreError: LocalizedError {
    case encodingFailure
    case invalidStoredRecord(String)
    case keychainFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailure:
            return "Could not encode the extension authorization record."
        case .invalidStoredRecord(let bundleIdentifier):
            return "The secure authorization record for \(bundleIdentifier) is invalid."
        case let .keychainFailure(operation, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not \(operation) the extension authorization record in Keychain: \(message)"
        }
    }
}
