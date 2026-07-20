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

enum MediaRemoteConsentSecureStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll").media-remote-consent"
    }
    private static let account = "bundled-adapter-v1"
    private static let allowedValue = Data("allowed-v1".utf8)

    static func isAllowed() throws -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data == allowedValue else {
                throw MediaRemoteConsentSecureStoreError.invalidStoredConsent
            }
            return true
        case errSecItemNotFound:
            return false
        default:
            throw MediaRemoteConsentSecureStoreError.keychainFailure(
                operation: "read",
                status: status
            )
        }
    }

    static func setAllowed(_ allowed: Bool) throws {
        if !allowed {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw MediaRemoteConsentSecureStoreError.keychainFailure(
                    operation: "delete",
                    status: status
                )
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: allowedValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MediaRemoteConsentSecureStoreError.keychainFailure(
                    operation: "create",
                    status: addStatus
                )
            }
        default:
            throw MediaRemoteConsentSecureStoreError.keychainFailure(
                operation: "update",
                status: updateStatus
            )
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

private enum MediaRemoteConsentSecureStoreError: LocalizedError {
    case invalidStoredConsent
    case keychainFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredConsent:
            return "The secure bundled-adapter consent record is invalid."
        case let .keychainFailure(operation, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not \(operation) bundled-adapter consent in Keychain: \(message)"
        }
    }
}
