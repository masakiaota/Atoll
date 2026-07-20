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

/// Keychain-backed source of truth for extension kill switches.
///
/// Defaults mirrors these values so existing views can react efficiently, but
/// an unrelated same-user process cannot enable an extension capability by
/// editing Preferences alone.
enum ExtensionSecurityPolicySecureStore {
    struct Policy: Codable, Hashable {
        var extensionsEnabled: Bool
        var liveActivitiesEnabled: Bool
        var lockScreenWidgetsEnabled: Bool
        var notchExperiencesEnabled: Bool
        var fileSharingEnabled: Bool
        var notchTabsEnabled: Bool
        var notchMinimalisticOverridesEnabled: Bool
        var notchInteractiveWebViewsEnabled: Bool

        static let secureDefault = Policy(
            extensionsEnabled: false,
            liveActivitiesEnabled: true,
            lockScreenWidgetsEnabled: true,
            notchExperiencesEnabled: true,
            fileSharingEnabled: false,
            notchTabsEnabled: true,
            notchMinimalisticOverridesEnabled: true,
            notchInteractiveWebViewsEnabled: true
        )
    }

    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll").extension-security-policy"
    }
    private static let account = "policy-v1"

    static func read() throws -> Policy? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let policy = try? JSONDecoder().decode(Policy.self, from: data) else {
                throw ExtensionSecurityPolicySecureStoreError.invalidStoredPolicy
            }
            return policy
        case errSecItemNotFound:
            return nil
        default:
            throw ExtensionSecurityPolicySecureStoreError.keychainFailure(
                operation: "read",
                status: status
            )
        }
    }

    static func save(_ policy: Policy) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(policy)
        } catch {
            throw ExtensionSecurityPolicySecureStoreError.encodingFailure
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
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
                throw ExtensionSecurityPolicySecureStoreError.keychainFailure(
                    operation: "create",
                    status: addStatus
                )
            }
        default:
            throw ExtensionSecurityPolicySecureStoreError.keychainFailure(
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

private enum ExtensionSecurityPolicySecureStoreError: LocalizedError {
    case encodingFailure
    case invalidStoredPolicy
    case keychainFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailure:
            return "Could not encode the extension security policy."
        case .invalidStoredPolicy:
            return "The secure extension policy is invalid."
        case let .keychainFailure(operation, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not \(operation) the extension security policy in Keychain: \(message)"
        }
    }
}
