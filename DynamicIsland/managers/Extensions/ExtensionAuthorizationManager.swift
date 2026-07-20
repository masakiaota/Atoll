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
import Defaults
import AtollExtensionKit

@MainActor
final class ExtensionAuthorizationManager: ObservableObject {
    static let shared = ExtensionAuthorizationManager()

    @Published private(set) var entries: [ExtensionAuthorizationEntry]
    @Published private(set) var rateLimitRecords: [ExtensionRateLimitRecord]
    @Published private(set) var securityPersistenceError: String?
    @Published private(set) var securityPolicy: ExtensionSecurityPolicySecureStore.Policy

    private let persistenceQueue = DispatchQueue(label: "com.atoll.extensions.authorization", qos: .utility)
    private var secureRecords: [String: ExtensionAuthorizationSecureStore.Record] = [:]
    /// A durable Keychain update can fail after a user requests revocation.
    /// Keep that bundle denied for the rest of the process even in that case.
    private var locallyBlockedBundles: Set<String> = []

    private init() {
        self.entries = Defaults[.extensionAuthorizationEntries]
        self.rateLimitRecords = Defaults[.extensionRateLimitRecords]
        self.securityPersistenceError = nil
        self.securityPolicy = .secureDefault
        normalizeState()
        loadSecurityPolicy()
        reconcileSecureAuthorizationState()
    }

    // MARK: - Public API

    var isExtensionsFeatureEnabled: Bool { securityPolicy.extensionsEnabled }
    var areLiveActivitiesEnabled: Bool { securityPolicy.liveActivitiesEnabled }
    var areLockScreenWidgetsEnabled: Bool { securityPolicy.lockScreenWidgetsEnabled }
    var areNotchExperiencesEnabled: Bool { securityPolicy.notchExperiencesEnabled }
    var isFileSharingEnabled: Bool { securityPolicy.fileSharingEnabled }
    var areNotchTabsEnabled: Bool { securityPolicy.notchTabsEnabled }
    var areNotchMinimalisticOverridesEnabled: Bool { securityPolicy.notchMinimalisticOverridesEnabled }
    var areNotchInteractiveWebViewsEnabled: Bool { securityPolicy.notchInteractiveWebViewsEnabled }

    /// Re-read the Keychain authority immediately before extension transports
    /// start. A duplicate process may have been suspended after its initial
    /// cache load and resumed only after the previous Atoll instance exited.
    func reloadSecurityAuthorityBeforeServing() {
        securityPolicy = .secureDefault
        secureRecords.removeAll()
        securityPersistenceError = nil
        loadSecurityPolicy()
        reconcileSecureAuthorizationState()
    }

    @discardableResult
    func updateFeatureToggles(extensionsEnabled: Bool? = nil,
                              liveActivitiesEnabled: Bool? = nil,
                              lockScreenWidgetsEnabled: Bool? = nil,
                              notchExperiencesEnabled: Bool? = nil,
                              fileSharingEnabled: Bool? = nil,
                              notchTabsEnabled: Bool? = nil,
                              notchMinimalisticOverridesEnabled: Bool? = nil,
                              notchInteractiveWebViewsEnabled: Bool? = nil) -> Bool {
        var candidate = securityPolicy
        if let extensionsEnabled { candidate.extensionsEnabled = extensionsEnabled }
        if let liveActivitiesEnabled { candidate.liveActivitiesEnabled = liveActivitiesEnabled }
        if let lockScreenWidgetsEnabled { candidate.lockScreenWidgetsEnabled = lockScreenWidgetsEnabled }
        if let notchExperiencesEnabled { candidate.notchExperiencesEnabled = notchExperiencesEnabled }
        if let fileSharingEnabled { candidate.fileSharingEnabled = fileSharingEnabled }
        if let notchTabsEnabled { candidate.notchTabsEnabled = notchTabsEnabled }
        if let notchMinimalisticOverridesEnabled {
            candidate.notchMinimalisticOverridesEnabled = notchMinimalisticOverridesEnabled
        }
        if let notchInteractiveWebViewsEnabled {
            candidate.notchInteractiveWebViewsEnabled = notchInteractiveWebViewsEnabled
        }

        let previousPolicy = securityPolicy
        do {
            try ExtensionSecurityPolicySecureStore.save(candidate)
        } catch {
            // A failed secure write must not keep a capability running after
            // the user tried to turn it off. Apply only the requested
            // reductions for this process; never apply an unsaved enable.
            applySecurityPolicy(intersection(of: previousPolicy, and: candidate))
            reportSecurityError("The extension setting was not changed because it could not be saved securely: \(error.localizedDescription)")
            return false
        }

        applySecurityPolicy(candidate)
        securityPersistenceError = nil
        return true
    }

    func authorizationEntry(for bundleIdentifier: String) -> ExtensionAuthorizationEntry? {
        entries.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Returns true only when the UI cache and the Keychain authority agree.
    func isBundleAuthorized(_ bundleIdentifier: String) -> Bool {
        guard isExtensionsFeatureEnabled,
              !locallyBlockedBundles.contains(bundleIdentifier),
              let entry = authorizationEntry(for: bundleIdentifier),
              entry.isAuthorized,
              let secureRecord = secureRecords[bundleIdentifier],
              secureRecord.isAuthorized else {
            return false
        }
        return entry.allowedScopes == secureRecord.allowedScopes
            && entry.trustedXPCCodeSigningRequirement == secureRecord.trustedXPCCodeSigningRequirement
    }

    func ensureEntryExists(bundleIdentifier: String, appName: String?) -> ExtensionAuthorizationEntry {
        if let existing = authorizationEntry(for: bundleIdentifier) {
            return existing
        }

        let resolvedName = appName ?? bundleIdentifier
        let entry = ExtensionAuthorizationEntry(
            bundleIdentifier: bundleIdentifier,
            appName: resolvedName,
            status: .pending,
            allowedScopes: defaultScopes()
        )
        entries.append(entry)
        persistEntries()
        return entry
    }

    /// Authorization is committed only after the previous RPC credential has
    /// been rotated and the new authority record is safely in Keychain.
    @discardableResult
    func authorize(bundleIdentifier: String,
                   appName: String?,
                   scopes: Set<ExtensionPermissionScope>? = nil) -> Bool {
        var candidate = ensureEntryExists(bundleIdentifier: bundleIdentifier, appName: appName)
        let requestedScopes = scopes ?? candidate.allowedScopes
        guard requestedScopes.isSubset(of: Set(ExtensionPermissionScope.allCases)) else {
            reportSecurityError("The requested extension permissions are invalid.")
            return false
        }

        do {
            try ExtensionRPCServer.shared.prepareAuthenticationForAuthorization(for: bundleIdentifier)
        } catch {
            locallyBlockedBundles.insert(bundleIdentifier)
            reportSecurityError("Authorization was not granted because the RPC credential could not be rotated: \(error.localizedDescription)")
            return false
        }

        candidate.appName = appName ?? candidate.appName
        candidate.status = .authorized
        candidate.allowedScopes = requestedScopes
        candidate.grantedAt = .now
        candidate.lastDeniedReason = nil
        if let pendingRequirement = candidate.pendingXPCCodeSigningRequirement {
            candidate.trustedXPCCodeSigningRequirement = pendingRequirement
            candidate.trustedXPCApplicationPath = candidate.pendingXPCApplicationPath
            candidate.pendingXPCCodeSigningRequirement = nil
            candidate.pendingXPCApplicationPath = nil
        }

        guard commitSecureEntry(candidate) else {
            locallyBlockedBundles.insert(bundleIdentifier)
            return false
        }
        locallyBlockedBundles.remove(bundleIdentifier)
        return true
    }

    @discardableResult
    func deny(bundleIdentifier: String, reason: String?) -> Bool {
        transitionToDeniedState(bundleIdentifier: bundleIdentifier, status: .denied, reason: reason)
    }

    @discardableResult
    func revoke(bundleIdentifier: String, reason: String?) -> Bool {
        transitionToDeniedState(bundleIdentifier: bundleIdentifier, status: .revoked, reason: reason)
    }

    /// Records the first identity seen for an XPC client without granting it.
    /// A conflicting candidate never replaces an existing pending identity;
    /// the user must reject or approve that candidate first.
    func registerPendingXPCIdentity(
        bundleIdentifier: String,
        appName: String,
        codeSigningRequirement: String,
        applicationPath: String?
    ) -> ExtensionAuthorizationEntry? {
        if let index = entries.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            var entry = entries[index]
            let secureRecord = secureRecords[bundleIdentifier]
            let trustedRequirement = secureRecord?.trustedXPCCodeSigningRequirement

            // Never use the Preferences copy as the trust decision. Reconcile it
            // from Keychain before displaying or comparing a candidate.
            entry.trustedXPCCodeSigningRequirement = trustedRequirement
            entry.trustedXPCApplicationPath = secureRecord?.trustedXPCApplicationPath

            if secureRecord?.isAuthorized == true,
               !locallyBlockedBundles.contains(bundleIdentifier),
               trustedRequirement == codeSigningRequirement {
                entry.trustedXPCApplicationPath = applicationPath ?? entry.trustedXPCApplicationPath
                entry.pendingXPCCodeSigningRequirement = nil
                entry.pendingXPCApplicationPath = nil
            } else if entry.pendingXPCCodeSigningRequirement == nil
                        || entry.pendingXPCCodeSigningRequirement == codeSigningRequirement {
                entry.pendingXPCCodeSigningRequirement = codeSigningRequirement
                entry.pendingXPCApplicationPath = applicationPath
                if secureRecord?.isAuthorized != true {
                    entry.appName = appName
                    entry.requestedAt = .now
                }
            }

            entries[index] = entry
            persistEntries()
            return entry
        }

        guard entries.count < 100 else { return nil }
        let entry = ExtensionAuthorizationEntry(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            status: .pending,
            allowedScopes: defaultScopes(),
            pendingXPCCodeSigningRequirement: codeSigningRequirement,
            pendingXPCApplicationPath: applicationPath
        )
        entries.append(entry)
        persistEntries()
        return entry
    }

    @discardableResult
    func approvePendingXPCIdentity(bundleIdentifier: String) -> Bool {
        guard !locallyBlockedBundles.contains(bundleIdentifier),
              let secureRecord = secureRecords[bundleIdentifier],
              secureRecord.isAuthorized,
              var candidate = authorizationEntry(for: bundleIdentifier),
              candidate.isAuthorized,
              let pendingRequirement = candidate.pendingXPCCodeSigningRequirement else {
            return false
        }

        candidate.trustedXPCCodeSigningRequirement = pendingRequirement
        candidate.trustedXPCApplicationPath = candidate.pendingXPCApplicationPath
        candidate.pendingXPCCodeSigningRequirement = nil
        candidate.pendingXPCApplicationPath = nil
        return commitSecureEntry(candidate)
    }

    func rejectPendingXPCIdentity(bundleIdentifier: String) {
        updateEntryMetadata(bundleIdentifier: bundleIdentifier) { entry in
            entry.pendingXPCCodeSigningRequirement = nil
            entry.pendingXPCApplicationPath = nil
        }
    }

    func isXPCIdentityAuthorized(
        bundleIdentifier: String,
        codeSigningRequirement: String
    ) -> Bool {
        guard isBundleAuthorized(bundleIdentifier),
              let entry = authorizationEntry(for: bundleIdentifier),
              let secureRecord = secureRecords[bundleIdentifier] else {
            return false
        }
        return entry.trustedXPCCodeSigningRequirement == codeSigningRequirement
            && secureRecord.trustedXPCCodeSigningRequirement == codeSigningRequirement
    }

    func recordActivity(for bundleIdentifier: String, scope: ExtensionPermissionScope) {
        updateEntryMetadata(bundleIdentifier: bundleIdentifier) { entry in
            entry.lastActivityAt = .now
        }

        updateRateLimitRecord(bundleIdentifier: bundleIdentifier) { record in
            let now = Date()
            switch scope {
            case .liveActivities:
                record.activityTimestamps.append(now)
            case .lockScreenWidgets:
                record.widgetTimestamps.append(now)
            case .notchExperiences:
                record.notchExperienceTimestamps.append(now)
            case .fileSharing:
                record.activityTimestamps.append(now)
            }
            record.activityTimestamps = flushOldTimestamps(record.activityTimestamps)
            record.widgetTimestamps = flushOldTimestamps(record.widgetTimestamps)
            record.notchExperienceTimestamps = flushOldTimestamps(record.notchExperienceTimestamps)
        }
    }

    @discardableResult
    func updateAllowedScopes(bundleIdentifier: String,
                             allowedScopes: Set<ExtensionPermissionScope>) -> Bool {
        guard allowedScopes.isSubset(of: Set(ExtensionPermissionScope.allCases)),
              !locallyBlockedBundles.contains(bundleIdentifier),
              let currentSecureRecord = secureRecords[bundleIdentifier],
              currentSecureRecord.isAuthorized,
              var candidate = authorizationEntry(for: bundleIdentifier),
              candidate.isAuthorized else {
            return false
        }

        let isNarrowingAccess = !allowedScopes.isSuperset(of: currentSecureRecord.allowedScopes)
        if isNarrowingAccess {
            locallyBlockedBundles.insert(bundleIdentifier)
            ExtensionRPCServer.shared.disconnectAuthorizationSessions(for: bundleIdentifier)
        }

        candidate.allowedScopes = allowedScopes
        guard commitSecureEntry(candidate) else { return false }
        if isNarrowingAccess {
            locallyBlockedBundles.remove(bundleIdentifier)
        }
        return true
    }

    func resetRateLimits(for bundleIdentifier: String) {
        rateLimitRecords.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistRateLimitRecords()
    }

    @discardableResult
    func removeEntry(bundleIdentifier: String) -> Bool {
        locallyBlockedBundles.insert(bundleIdentifier)
        ExtensionRPCServer.shared.disconnectAuthorizationSessions(for: bundleIdentifier)

        let current = authorizationEntry(for: bundleIdentifier)
        let record = ExtensionAuthorizationSecureStore.Record(
            bundleIdentifier: bundleIdentifier,
            appName: current?.appName ?? secureRecords[bundleIdentifier]?.appName ?? bundleIdentifier,
            status: .revoked,
            allowedScopes: defaultScopes(),
            trustedXPCCodeSigningRequirement: nil,
            trustedXPCApplicationPath: nil,
            isRemoved: true
        )

        guard saveSecureRecord(record) else { return false }
        entries.removeAll { $0.bundleIdentifier == bundleIdentifier }
        rateLimitRecords.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistEntries()
        persistRateLimitRecords()
        deleteRPCTokenAfterRevocation(for: bundleIdentifier)
        return true
    }

    // MARK: - Validation Helpers

    func canProcessLiveActivityRequest(from bundleIdentifier: String) -> Bool {
        preflight(bundleIdentifier: bundleIdentifier, scope: .liveActivities)
            && areLiveActivitiesEnabled
    }

    func canProcessLockScreenRequest(from bundleIdentifier: String) -> Bool {
        preflight(bundleIdentifier: bundleIdentifier, scope: .lockScreenWidgets)
            && areLockScreenWidgetsEnabled
    }

    func canProcessNotchExperienceRequest(from bundleIdentifier: String) -> Bool {
        preflight(bundleIdentifier: bundleIdentifier, scope: .notchExperiences)
            && areNotchExperiencesEnabled
    }

    func canProcessFileSharingRequest(from bundleIdentifier: String) -> Bool {
        isFileSharingEnabled
            && preflight(bundleIdentifier: bundleIdentifier, scope: .fileSharing)
    }

    func recordDeniedRequest(bundleIdentifier: String, reason: String) {
        if secureRecords[bundleIdentifier]?.isAuthorized == true {
            _ = revoke(bundleIdentifier: bundleIdentifier, reason: reason)
        } else {
            updateEntryMetadata(bundleIdentifier: bundleIdentifier) { entry in
                entry.lastDeniedReason = reason
            }
        }
    }

    // MARK: - Internal State Updates

    @discardableResult
    private func transitionToDeniedState(
        bundleIdentifier: String,
        status: ExtensionAuthorizationStatus,
        reason: String?
    ) -> Bool {
        locallyBlockedBundles.insert(bundleIdentifier)
        ExtensionRPCServer.shared.disconnectAuthorizationSessions(for: bundleIdentifier)

        var candidate = ensureEntryExists(bundleIdentifier: bundleIdentifier, appName: bundleIdentifier)
        candidate.status = status
        candidate.grantedAt = nil
        candidate.lastDeniedReason = reason
        candidate.pendingXPCCodeSigningRequirement = nil
        candidate.pendingXPCApplicationPath = nil

        guard commitSecureEntry(candidate) else { return false }
        deleteRPCTokenAfterRevocation(for: bundleIdentifier)
        return true
    }

    private func updateEntryMetadata(
        bundleIdentifier: String,
        mutate: (inout ExtensionAuthorizationEntry) -> Void
    ) {
        guard let index = entries.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            var entry = ensureEntryExists(bundleIdentifier: bundleIdentifier, appName: bundleIdentifier)
            mutate(&entry)
            entries.removeAll { $0.bundleIdentifier == bundleIdentifier }
            entries.append(entry)
            persistEntries()
            return
        }
        var entry = entries[index]
        mutate(&entry)
        entries[index] = entry
        persistEntries()
    }

    private func updateRateLimitRecord(bundleIdentifier: String,
                                       mutate: (inout ExtensionRateLimitRecord) -> Void) {
        if let index = rateLimitRecords.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            var record = rateLimitRecords[index]
            mutate(&record)
            rateLimitRecords[index] = record
            persistRateLimitRecords()
        } else {
            var newRecord = ExtensionRateLimitRecord(bundleIdentifier: bundleIdentifier)
            mutate(&newRecord)
            rateLimitRecords.append(newRecord)
            persistRateLimitRecords()
        }
    }

    private func preflight(bundleIdentifier: String, scope: ExtensionPermissionScope) -> Bool {
        guard isBundleAuthorized(bundleIdentifier),
              let entry = authorizationEntry(for: bundleIdentifier),
              entry.allowedScopes.contains(scope),
              let secureRecord = secureRecords[bundleIdentifier],
              secureRecord.allowedScopes.contains(scope) else {
            return false
        }
        return true
    }

    private func commitSecureEntry(_ entry: ExtensionAuthorizationEntry) -> Bool {
        let record = ExtensionAuthorizationSecureStore.Record(
            bundleIdentifier: entry.bundleIdentifier,
            appName: entry.appName,
            status: entry.status,
            allowedScopes: entry.allowedScopes,
            trustedXPCCodeSigningRequirement: entry.trustedXPCCodeSigningRequirement,
            trustedXPCApplicationPath: entry.trustedXPCApplicationPath,
            isRemoved: false
        )
        guard saveSecureRecord(record) else { return false }

        if let index = entries.firstIndex(where: { $0.bundleIdentifier == entry.bundleIdentifier }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persistEntries()
        return true
    }

    private func saveSecureRecord(_ record: ExtensionAuthorizationSecureStore.Record) -> Bool {
        do {
            try ExtensionAuthorizationSecureStore.save(record)
            secureRecords[record.bundleIdentifier] = record
            securityPersistenceError = nil
            return true
        } catch {
            reportSecurityError("The extension authorization change was blocked because it could not be saved securely: \(error.localizedDescription)")
            return false
        }
    }

    private func deleteRPCTokenAfterRevocation(for bundleIdentifier: String) {
        do {
            try ExtensionRPCServer.shared.deleteAuthenticationToken(for: bundleIdentifier)
        } catch {
            // The Keychain authorization record is already non-authorized and
            // the live connection was disconnected first, so this remains safe.
            reportSecurityError("Access was revoked, but the obsolete RPC token could not be removed: \(error.localizedDescription)")
        }
    }

    private func reportSecurityError(_ message: String) {
        securityPersistenceError = message
    }

    private func flushOldTimestamps(_ timestamps: [Date]) -> [Date] {
        let threshold = Date().addingTimeInterval(-60 * 5)
        return timestamps.filter { $0 >= threshold }
    }

    private func defaultScopes() -> Set<ExtensionPermissionScope> {
        [.liveActivities, .lockScreenWidgets, .notchExperiences]
    }

    private func persistEntries() {
        let entriesSnapshot = entries
        persistenceQueue.async {
            Defaults[.extensionAuthorizationEntries] = entriesSnapshot
        }
    }

    private func persistRateLimitRecords() {
        let recordsSnapshot = rateLimitRecords
        persistenceQueue.async {
            Defaults[.extensionRateLimitRecords] = recordsSnapshot
        }
    }

    private func normalizeState() {
        var seenBundleIdentifiers: Set<String> = []
        entries = Array(entries.lazy.filter { entry in
            guard !entry.bundleIdentifier.isEmpty,
                  seenBundleIdentifiers.insert(entry.bundleIdentifier).inserted else {
                return false
            }
            return true
        }.prefix(100))
        rateLimitRecords = rateLimitRecords.filter { !$0.bundleIdentifier.isEmpty }
    }

    private func loadSecurityPolicy() {
        do {
            if let storedPolicy = try ExtensionSecurityPolicySecureStore.read() {
                securityPolicy = storedPolicy
            } else {
                let safePolicy = ExtensionSecurityPolicySecureStore.Policy.secureDefault
                try ExtensionSecurityPolicySecureStore.save(safePolicy)
                securityPolicy = safePolicy
            }
            mirrorSecurityPolicyToPreferences()
        } catch {
            securityPolicy = .secureDefault
            mirrorSecurityPolicyToPreferences()
            reportSecurityError("Extensions remain disabled because their security policy could not be loaded from Keychain: \(error.localizedDescription)")
        }
    }

    private func mirrorSecurityPolicyToPreferences() {
        Defaults[.enableThirdPartyExtensions] = securityPolicy.extensionsEnabled
        Defaults[.enableExtensionLiveActivities] = securityPolicy.liveActivitiesEnabled
        Defaults[.enableExtensionLockScreenWidgets] = securityPolicy.lockScreenWidgetsEnabled
        Defaults[.enableExtensionNotchExperiences] = securityPolicy.notchExperiencesEnabled
        Defaults[.enableExtensionFileSharing] = securityPolicy.fileSharingEnabled
        Defaults[.enableExtensionNotchTabs] = securityPolicy.notchTabsEnabled
        Defaults[.enableExtensionNotchMinimalisticOverrides] = securityPolicy.notchMinimalisticOverridesEnabled
        Defaults[.enableExtensionNotchInteractiveWebViews] = securityPolicy.notchInteractiveWebViewsEnabled
    }

    private func applySecurityPolicy(_ candidate: ExtensionSecurityPolicySecureStore.Policy) {
        let previous = securityPolicy
        securityPolicy = candidate
        mirrorSecurityPolicyToPreferences()

        if previous.extensionsEnabled && !candidate.extensionsEnabled {
            for entry in entries {
                ExtensionRPCServer.shared.disconnectAuthorizationSessions(for: entry.bundleIdentifier)
            }
        }
        if previous.notchInteractiveWebViewsEnabled
            && !candidate.notchInteractiveWebViewsEnabled {
            ExtensionNotchExperienceManager.shared.dismissInteractiveWebContent()
        }
    }

    private func intersection(
        of lhs: ExtensionSecurityPolicySecureStore.Policy,
        and rhs: ExtensionSecurityPolicySecureStore.Policy
    ) -> ExtensionSecurityPolicySecureStore.Policy {
        .init(
            extensionsEnabled: lhs.extensionsEnabled && rhs.extensionsEnabled,
            liveActivitiesEnabled: lhs.liveActivitiesEnabled && rhs.liveActivitiesEnabled,
            lockScreenWidgetsEnabled: lhs.lockScreenWidgetsEnabled && rhs.lockScreenWidgetsEnabled,
            notchExperiencesEnabled: lhs.notchExperiencesEnabled && rhs.notchExperiencesEnabled,
            fileSharingEnabled: lhs.fileSharingEnabled && rhs.fileSharingEnabled,
            notchTabsEnabled: lhs.notchTabsEnabled && rhs.notchTabsEnabled,
            notchMinimalisticOverridesEnabled: lhs.notchMinimalisticOverridesEnabled
                && rhs.notchMinimalisticOverridesEnabled,
            notchInteractiveWebViewsEnabled: lhs.notchInteractiveWebViewsEnabled
                && rhs.notchInteractiveWebViewsEnabled
        )
    }

    /// Preferences are only a display cache. On launch, every security-relevant
    /// value is replaced by the Keychain copy; missing or unreadable records are
    /// downgraded to a fresh pending request with safe default scopes.
    private func reconcileSecureAuthorizationState() {
        var reconciledEntries: [ExtensionAuthorizationEntry] = []

        for var entry in entries {
            entry.pendingXPCCodeSigningRequirement = nil
            entry.pendingXPCApplicationPath = nil

            do {
                guard let secureRecord = try ExtensionAuthorizationSecureStore.readRecord(
                    for: entry.bundleIdentifier
                ) else {
                    downgradeToPending(&entry)
                    reconciledEntries.append(entry)
                    continue
                }

                secureRecords[entry.bundleIdentifier] = secureRecord
                guard !secureRecord.isRemoved else { continue }

                entry.appName = secureRecord.appName
                entry.status = secureRecord.status
                entry.allowedScopes = secureRecord.allowedScopes
                entry.trustedXPCCodeSigningRequirement = secureRecord.trustedXPCCodeSigningRequirement
                entry.trustedXPCApplicationPath = secureRecord.trustedXPCApplicationPath
                if !secureRecord.isAuthorized {
                    entry.grantedAt = nil
                }
                reconciledEntries.append(entry)
            } catch {
                downgradeToPending(&entry)
                reconciledEntries.append(entry)
                reportSecurityError("An extension authorization record could not be read securely and was disabled: \(error.localizedDescription)")
            }
        }

        entries = reconciledEntries
        persistEntries()
    }

    private func downgradeToPending(_ entry: inout ExtensionAuthorizationEntry) {
        entry.status = .pending
        entry.allowedScopes = defaultScopes()
        entry.grantedAt = nil
        entry.trustedXPCCodeSigningRequirement = nil
        entry.trustedXPCApplicationPath = nil
        entry.pendingXPCCodeSigningRequirement = nil
        entry.pendingXPCApplicationPath = nil
    }
}
