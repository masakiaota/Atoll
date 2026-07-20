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

import AppKit
import CryptoKit
import SwiftUI
import Defaults
import AtollExtensionKit

struct ExtensionsSettingsView: View {
    @ObservedObject private var authManager = ExtensionAuthorizationManager.shared
    @State private var searchText = ""
    @State private var selectedEntry: ExtensionAuthorizationEntry?
    @State private var showingRemoveConfirmation = false
    
    private func highlightID(_ title: String) -> String {
        "extensions-\(title)"
    }
    
    private var filteredEntries: [ExtensionAuthorizationEntry] {
        guard !searchText.isEmpty else { return authManager.entries }
        let query = searchText.lowercased()
        return authManager.entries.filter {
            $0.bundleIdentifier.lowercased().contains(query) ||
            $0.appName.lowercased().contains(query)
        }
    }

    private var extensionsEnabled: Bool {
        authManager.isExtensionsFeatureEnabled
    }
    
    var body: some View {
        Form {
            if let securityError = authManager.securityPersistenceError {
                Section {
                    Label(securityError, systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text("Security state not saved")
                }
            }

            globalTogglesSection
            
            if extensionsEnabled {
                localRPCSection
                authorizedAppsSection
            }
        }
        .navigationTitle("Extensions")
        .alert("Remove Extension", isPresented: $showingRemoveConfirmation, presenting: selectedEntry) { entry in
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if authManager.removeEntry(bundleIdentifier: entry.bundleIdentifier) {
                    dismissAllContent(for: entry.bundleIdentifier)
                    notifyAuthorizationChange(for: entry.bundleIdentifier, isAuthorized: false)
                    selectedEntry = nil
                }
            }
        } message: { entry in
            Text("Remove \(entry.appName) from the authorized extensions list? This will dismiss all active live activities, lock screen widgets, and notch experiences from this app.")
        }
    }
    
    private var globalTogglesSection: some View {
        Section {
            Toggle(
                String(localized: "Enable third-party extensions"),
                isOn: Binding(
                    get: { authManager.isExtensionsFeatureEnabled },
                    set: { _ = authManager.updateFeatureToggles(extensionsEnabled: $0) }
                )
            )
                .settingsHighlight(id: highlightID("Enable third-party extensions"))
            
            if extensionsEnabled {
                Toggle(
                    String(localized: "Allow extension live activities"),
                    isOn: Binding(
                        get: { authManager.areLiveActivitiesEnabled },
                        set: { _ = authManager.updateFeatureToggles(liveActivitiesEnabled: $0) }
                    )
                )
                    .settingsHighlight(id: highlightID("Allow extension live activities"))
                
                Toggle(
                    String(localized: "Allow extension lock screen widgets"),
                    isOn: Binding(
                        get: { authManager.areLockScreenWidgetsEnabled },
                        set: { _ = authManager.updateFeatureToggles(lockScreenWidgetsEnabled: $0) }
                    )
                )
                    .settingsHighlight(id: highlightID("Allow extension lock screen widgets"))

                Toggle(
                    String(localized: "Allow extension notch experiences"),
                    isOn: Binding(
                        get: { authManager.areNotchExperiencesEnabled },
                        set: { _ = authManager.updateFeatureToggles(notchExperiencesEnabled: $0) }
                    )
                )
                    .settingsHighlight(id: highlightID("Allow extension notch experiences"))

                Toggle(
                    String(localized: "Allow extensions to access Shelf files"),
                    isOn: Binding(
                        get: { authManager.isFileSharingEnabled },
                        set: { _ = authManager.updateFeatureToggles(fileSharingEnabled: $0) }
                    )
                )
                    .settingsHighlight(id: highlightID("Allow extension file sharing"))

                if authManager.areNotchExperiencesEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            String(localized: "Show extension tabs"),
                            isOn: Binding(
                                get: { authManager.areNotchTabsEnabled },
                                set: { _ = authManager.updateFeatureToggles(notchTabsEnabled: $0) }
                            )
                        )
                            .tint(.accentColor)
                        Toggle(
                            String(localized: "Allow minimalistic overrides"),
                            isOn: Binding(
                                get: { authManager.areNotchMinimalisticOverridesEnabled },
                                set: { _ = authManager.updateFeatureToggles(notchMinimalisticOverridesEnabled: $0) }
                            )
                        )
                            .tint(.accentColor)
                        Toggle(
                            String(localized: "Allow interactive web content"),
                            isOn: Binding(
                                get: { authManager.areNotchInteractiveWebViewsEnabled },
                                set: { _ = authManager.updateFeatureToggles(notchInteractiveWebViewsEnabled: $0) }
                            )
                        )
                            .tint(.accentColor)
                    }
                    .padding(.leading, 4)
                }
                
                Defaults.Toggle(String(localized:"Enable extension diagnostics logging"), key: .extensionDiagnosticsLoggingEnabled)
                    .settingsHighlight(id: highlightID("Enable extension diagnostics logging"))
            }
        } header: {
            Text("Global Settings")
        } footer: {
            if extensionsEnabled {
                Text("Third-party apps can request access, but remain blocked until authorized below. Shelf access additionally requires both the global file-sharing switch and the app-specific permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enable extensions to allow third-party apps to display live activities and lock screen widgets in Atoll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localRPCSection: some View {
        Section {
            LabeledContent("Endpoint") {
                Text("ws://localhost:9020")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Local RPC")
        } footer: {
            Text("RPC accepts WebSocket connections from this Mac only. A custom client first sends atoll.requestAuthorization with its bundle identifier. After approval, it must use the AtollRPC/2 begin/complete handshake and encrypted frames. The token is never sent on the wire. Update legacy clients before connecting; see LOCAL_RPC_PROTOCOL.md in this repository.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dismissAllContent(for bundleIdentifier: String) {
        ExtensionLiveActivityManager.shared.dismissAll(for: bundleIdentifier)
        ExtensionLockScreenWidgetManager.shared.dismissAll(for: bundleIdentifier)
        ExtensionNotchExperienceManager.shared.dismissAll(for: bundleIdentifier)
    }

    private func notifyAuthorizationChange(for bundleIdentifier: String, isAuthorized: Bool) {
        ExtensionRPCServer.shared.notifyAuthorizationChange(
            bundleIdentifier: bundleIdentifier,
            isAuthorized: isAuthorized
        )
        ExtensionXPCServiceHost.shared.notifyAuthorizationChange(
            bundleIdentifier: bundleIdentifier,
            isAuthorized: isAuthorized
        )
    }
    
    private var authorizedAppsSection: some View {
        Section {
            if authManager.entries.isEmpty {
                VStack(alignment: .center, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    
                    Text("No extensions yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text("Apps using AtollExtensionKit will appear here once they request permission")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                if authManager.entries.count > 3 {
                    TextField("Search extensions...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                
                ForEach(filteredEntries) { entry in
                    ExtensionEntryRow(entry: entry, onRemove: {
                        selectedEntry = entry
                        showingRemoveConfirmation = true
                    })
                }
            }
        } header: {
            HStack {
                Text("App Permissions")
                Spacer()
                if !authManager.entries.isEmpty {
                    Text("\(authManager.entries.count) \(authManager.entries.count == 1 ? "app" : "apps")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsHighlight(id: highlightID("App permissions list"))
        } footer: {
            if !authManager.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permission States:")
                        .font(.caption.weight(.semibold))
                    
                    HStack(spacing: 16) {
                        Label("Authorized", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("Pending", systemImage: "clock.fill")
                            .foregroundStyle(.orange)
                        Label("Denied/Revoked", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct ExtensionEntryRow: View {
    @ObservedObject private var authManager = ExtensionAuthorizationManager.shared
    @ObservedObject private var liveActivityManager = ExtensionLiveActivityManager.shared
    @ObservedObject private var widgetManager = ExtensionLockScreenWidgetManager.shared
    @ObservedObject private var notchExperienceManager = ExtensionNotchExperienceManager.shared
    let entry: ExtensionAuthorizationEntry
    let onRemove: () -> Void
    
    @State private var isExpanded = false
    @State private var showingTokenRegenerationConfirmation = false
    @State private var rpcTokenMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Status indicator
                statusIndicator
                
                // App info
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.appName)
                        .font(.system(size: 13, weight: .medium))
                    Text(entry.bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Expand button
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
            
            // Expanded details
            if isExpanded {
                expandedDetails
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
        .alert("Regenerate RPC Token?", isPresented: $showingTokenRegenerationConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                regenerateAndCopyRPCToken()
            }
        } message: {
            Text("Existing RPC connections for \(entry.appName) will be disconnected. The new token will be copied to the clipboard.")
        }
    }
    
    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 32, height: 32)
            
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch entry.status {
        case .authorized: return .green
        case .pending: return .orange
        case .denied, .revoked: return .red
        }
    }
    
    private var statusIcon: String {
        switch entry.status {
        case .authorized: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .denied, .revoked: return "xmark.circle.fill"
        }
    }
    
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Status info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Status:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.status.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.15))
                        .foregroundStyle(statusColor)
                        .clipShape(Capsule())
                }
                
                if let grantedAt = entry.grantedAt {
                    infoRow(label: "Granted", value: formatDate(grantedAt))
                }
                
                if let lastActivity = entry.lastActivityAt {
                    infoRow(label: "Last Activity", value: formatDate(lastActivity))
                }
                
                if let deniedReason = entry.lastDeniedReason {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last Denied Reason:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(deniedReason)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
            }
            
            Divider()

            if let pendingRequirement = entry.pendingXPCCodeSigningRequirement {
                pendingXPCIdentityControls(requirement: pendingRequirement)
                Divider()
            }
            
            // Scopes section
            if entry.status == .authorized {
                scopeToggles
                Divider()
                rpcTokenControls
                Divider()
            }
            
            // Rate limits info
                if let rateLimitRecord = authManager.rateLimitRecords.first(where: { $0.bundleIdentifier == entry.bundleIdentifier }),
                    !rateLimitRecord.activityTimestamps.isEmpty || !rateLimitRecord.widgetTimestamps.isEmpty || !rateLimitRecord.notchExperienceTimestamps.isEmpty {
                rateLimitInfo(record: rateLimitRecord)
                Divider()
            }
            
            // Actions
            actionButtons
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pendingXPCIdentityControls(requirement: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("XPC identity awaiting approval", systemImage: "signature")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            if let path = entry.pendingXPCApplicationPath {
                infoRow(label: "Application", value: path)
                    .textSelection(.enabled)
            }
            infoRow(label: "Identity", value: xpcIdentityFingerprint(requirement))
                .textSelection(.enabled)

            Text("Approve only if this path belongs to the extension build you intended to connect. A rebuilt ad-hoc client may legitimately require approval again.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.status == .authorized {
                HStack(spacing: 8) {
                    Button("Approve XPC Build") {
                        if authManager.approvePendingXPCIdentity(
                            bundleIdentifier: entry.bundleIdentifier
                        ) {
                            notifyAuthorizationChange(isAuthorized: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Reject") {
                        authManager.rejectPendingXPCIdentity(
                            bundleIdentifier: entry.bundleIdentifier
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func xpcIdentityFingerprint(_ requirement: String) -> String {
        SHA256.hash(data: Data(requirement.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var rpcTokenControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local RPC Token")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Copy Token") {
                    copyRPCToken()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Regenerate") {
                    showingTokenRegenerationConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let rpcTokenMessage {
                Text(rpcTokenMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("AtollRPC/2 uses this token only for mutual proofs and encrypted session keys. Clients must use atoll.secure.begin and atoll.secure.complete; sending the token as authenticationToken is rejected. See LOCAL_RPC_PROTOCOL.md in this repository for the wire format.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var scopeToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allowed Features")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            Toggle("Live Activities", isOn: Binding(
                get: { entry.allowedScopes.contains(.liveActivities) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.liveActivities)
                    } else {
                        newScopes.remove(.liveActivities)
                    }
                    if authManager.updateAllowedScopes(
                        bundleIdentifier: entry.bundleIdentifier,
                        allowedScopes: newScopes
                    ), !enabled {
                        liveActivityManager.dismissAll(for: entry.bundleIdentifier)
                    }
                }
            ))
            .font(.caption)
            .disabled(!authManager.areLiveActivitiesEnabled)
            
            Toggle("Lock Screen Widgets", isOn: Binding(
                get: { entry.allowedScopes.contains(.lockScreenWidgets) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.lockScreenWidgets)
                    } else {
                        newScopes.remove(.lockScreenWidgets)
                    }
                    if authManager.updateAllowedScopes(
                        bundleIdentifier: entry.bundleIdentifier,
                        allowedScopes: newScopes
                    ), !enabled {
                        widgetManager.dismissAll(for: entry.bundleIdentifier)
                    }
                }
            ))
            .font(.caption)
            .disabled(!authManager.areLockScreenWidgetsEnabled)

            Toggle("Notch Experiences", isOn: Binding(
                get: { entry.allowedScopes.contains(.notchExperiences) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.notchExperiences)
                    } else {
                        newScopes.remove(.notchExperiences)
                    }
                    if authManager.updateAllowedScopes(
                        bundleIdentifier: entry.bundleIdentifier,
                        allowedScopes: newScopes
                    ), !enabled {
                        notchExperienceManager.dismissAll(for: entry.bundleIdentifier)
                    }
                }
            ))
            .font(.caption)
            .disabled(!authManager.areNotchExperiencesEnabled)

            Toggle("Shelf File Access", isOn: Binding(
                get: { entry.allowedScopes.contains(.fileSharing) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.fileSharing)
                    } else {
                        newScopes.remove(.fileSharing)
                    }
                    _ = authManager.updateAllowedScopes(
                        bundleIdentifier: entry.bundleIdentifier,
                        allowedScopes: newScopes
                    )
                }
            ))
            .font(.caption)
            .disabled(!authManager.isFileSharingEnabled)
        }
    }
    
    private func rateLimitInfo(record: ExtensionRateLimitRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity (last 5 minutes)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 20) {
                if !record.activityTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Activities")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(record.activityTimestamps.count)")
                            .font(.caption.monospacedDigit())
                    }
                }
                
                if !record.widgetTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Widget Updates")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(record.widgetTimestamps.count)")
                            .font(.caption.monospacedDigit())
                    }
                }

                if !record.notchExperienceTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch Experiences")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(record.notchExperienceTimestamps.count)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            
            Button("Reset Rate Limits") {
                authManager.resetRateLimits(for: entry.bundleIdentifier)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            switch entry.status {
            case .pending:
                Button(entry.pendingXPCCodeSigningRequirement == nil ? "Authorize" : "Authorize App + XPC Build") {
                    if authManager.authorize(bundleIdentifier: entry.bundleIdentifier, appName: entry.appName) {
                        notifyAuthorizationChange(isAuthorized: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button("Deny") {
                    if authManager.deny(bundleIdentifier: entry.bundleIdentifier, reason: "Denied by user") {
                        dismissAllContent()
                        notifyAuthorizationChange(isAuthorized: false)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
            case .authorized:
                Button("Revoke Access") {
                    if authManager.revoke(bundleIdentifier: entry.bundleIdentifier, reason: "Revoked by user") {
                        dismissAllContent()
                        notifyAuthorizationChange(isAuthorized: false)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                
            case .denied, .revoked:
                Button(entry.pendingXPCCodeSigningRequirement == nil ? "Re-authorize" : "Re-authorize App + XPC Build") {
                    if authManager.authorize(bundleIdentifier: entry.bundleIdentifier, appName: entry.appName) {
                        notifyAuthorizationChange(isAuthorized: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            Spacer()
            
            resetMenu

            Button("Remove") {
                onRemove()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    private func notifyAuthorizationChange(isAuthorized: Bool) {
        ExtensionRPCServer.shared.notifyAuthorizationChange(
            bundleIdentifier: entry.bundleIdentifier,
            isAuthorized: isAuthorized
        )
        ExtensionXPCServiceHost.shared.notifyAuthorizationChange(
            bundleIdentifier: entry.bundleIdentifier,
            isAuthorized: isAuthorized
        )
    }

    private func dismissAllContent() {
        liveActivityManager.dismissAll(for: entry.bundleIdentifier)
        widgetManager.dismissAll(for: entry.bundleIdentifier)
        notchExperienceManager.dismissAll(for: entry.bundleIdentifier)
    }

    private func copyRPCToken() {
        do {
            let token = try ExtensionRPCServer.shared.authenticationToken(
                for: entry.bundleIdentifier
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(token, forType: .string)
            rpcTokenMessage = "Token copied to the clipboard."
        } catch {
            rpcTokenMessage = "Could not copy the token: \(error.localizedDescription)"
        }
    }

    private func regenerateAndCopyRPCToken() {
        do {
            let token = try ExtensionRPCServer.shared.regenerateAuthenticationToken(
                for: entry.bundleIdentifier
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(token, forType: .string)
            rpcTokenMessage = "A new token was copied to the clipboard."
        } catch {
            rpcTokenMessage = "Could not regenerate the token: \(error.localizedDescription)"
        }
    }

    private var resetMenu: some View {
        Menu {
            Button("Reset Live Activities") {
                liveActivityManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasLiveActivities)

            Button("Reset Lock Screen Widgets") {
                widgetManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasWidgets)

            Button("Reset Notch Experiences") {
                notchExperienceManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasNotchExperiences)
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var hasLiveActivities: Bool {
        liveActivityManager.activeActivities.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }

    private var hasWidgets: Bool {
        widgetManager.activeWidgets.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }

    private var hasNotchExperiences: Bool {
        notchExperienceManager.activeExperiences.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }
    
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

#Preview {
    ExtensionsSettingsView()
}
