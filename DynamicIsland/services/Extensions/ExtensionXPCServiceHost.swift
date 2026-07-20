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
import Foundation
import Security
import AtollExtensionKit

/// Shared constants for the Atoll extension XPC service.
enum ExtensionXPCServiceConstants {
    static let machServiceName = "com.ebullioscopic.Atoll.xpc"
}

private struct ExtensionXPCPeerIdentity: Sendable {
    let bundleIdentifier: String
    let codeSigningRequirement: String
    let applicationPath: String?
}

/// Carries Foundation XPC objects from the listener's private queue to the
/// main actor, where all host state and exported services are configured.
private final class ExtensionXPCPendingConnection: @unchecked Sendable {
    let listener: NSXPCListener
    let connection: NSXPCConnection
    let peerIdentity: ExtensionXPCPeerIdentity

    init(
        listener: NSXPCListener,
        connection: NSXPCConnection,
        peerIdentity: ExtensionXPCPeerIdentity
    ) {
        self.listener = listener
        self.connection = connection
        self.peerIdentity = peerIdentity
    }
}

@MainActor
final class ExtensionXPCServiceHost: NSObject, NSXPCListenerDelegate {
    static let shared = ExtensionXPCServiceHost()
    private static let maximumClientConnections = 64

    private final class ClientContext {
        let connection: NSXPCConnection
        let bundleIdentifier: String
        let codeSigningRequirement: String

        init(
            connection: NSXPCConnection,
            bundleIdentifier: String,
            codeSigningRequirement: String
        ) {
            self.connection = connection
            self.bundleIdentifier = bundleIdentifier
            self.codeSigningRequirement = codeSigningRequirement
        }
    }

    private var listener: NSXPCListener?
    private var clientContexts: [ObjectIdentifier: ClientContext] = [:]

    func start() {
        guard listener == nil else { return }

        // In UI testing environments (like CI), the mach-services entitlement might be stripped
        // to bypass amfid ad-hoc signing crashes. Starting the listener without the entitlement crashes the app.
        if AppRuntimeEnvironment.isUITesting {
            Logger.log("Bypassing Atoll XPC listener for UI testing", category: .extensions)
            return
        }

        let listener = NSXPCListener(machServiceName: ExtensionXPCServiceConstants.machServiceName)
        listener.delegate = self
        self.listener = listener
        listener.resume()

        Logger.log("Started Atoll XPC listener", category: .extensions)
    }

    func stop() {
        listener?.invalidate()
        listener = nil

        let activeConnections = clientContexts.values.map(\.connection)
        clientContexts.removeAll()
        for connection in activeConnections {
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
        }
        Logger.log("Stopped Atoll XPC listener", category: .extensions)
    }

    /// NSXPCListener invokes its delegate on a private serial queue. Keep this
    /// entry point nonisolated and move every access to host state onto the main
    /// actor before the suspended connection is configured or resumed.
    nonisolated func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let peerIdentity = Self.resolvePeerIdentity(for: connection) else {
            return false
        }

        // Pin every message on this connection to the designated requirement derived
        // from the validated running peer. A PID/bundle identifier lookup alone is not
        // a sufficient authentication boundary and is vulnerable to process races.
        connection.setCodeSigningRequirement(peerIdentity.codeSigningRequirement)

        let pendingConnection = ExtensionXPCPendingConnection(
            listener: listener,
            connection: connection,
            peerIdentity: peerIdentity
        )
        Task { @MainActor [weak self] in
            guard let self else {
                pendingConnection.connection.invalidate()
                return
            }
            self.configure(pendingConnection)
        }

        // Returning true without immediately resuming is supported by
        // NSXPCListener. The main actor resumes the connection after it has
        // revalidated that this listener is still current.
        return true
    }

    private func configure(_ pendingConnection: ExtensionXPCPendingConnection) {
        let connection = pendingConnection.connection
        guard listener === pendingConnection.listener else {
            connection.invalidate()
            Logger.log("Rejected XPC connection from a stale listener", category: .extensions)
            return
        }
        guard clientContexts.count < Self.maximumClientConnections else {
            connection.invalidate()
            return
        }

        let peerIdentity = pendingConnection.peerIdentity
        let bundleIdentifier = peerIdentity.bundleIdentifier
        let service = ExtensionXPCService(
            bundleIdentifier: bundleIdentifier,
            codeSigningRequirement: peerIdentity.codeSigningRequirement,
            applicationPath: peerIdentity.applicationPath,
            connection: connection
        )
        connection.exportedInterface = NSXPCInterface(with: AtollXPCServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: AtollXPCClientProtocol.self)

        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        clientContexts[ObjectIdentifier(connection)] = ClientContext(
            connection: connection,
            bundleIdentifier: bundleIdentifier,
            codeSigningRequirement: peerIdentity.codeSigningRequirement
        )
        connection.resume()
        Logger.log("Accepted XPC connection from \(bundleIdentifier)", category: .extensions)
    }

    func notifyAuthorizationChange(bundleIdentifier: String, isAuthorized: Bool) {
        deliver(to: bundleIdentifier, requiresAuthorizedIdentity: isAuthorized) { client in
            client.authorizationDidChange(isAuthorized: isAuthorized)
        }
    }

    func notifyActivityDismiss(bundleIdentifier: String, activityID: String) {
        deliver(to: bundleIdentifier) { client in
            client.activityDidDismiss(activityID: activityID)
        }
    }

    func notifyWidgetDismiss(bundleIdentifier: String, widgetID: String) {
        deliver(to: bundleIdentifier) { client in
            client.widgetDidDismiss(widgetID: widgetID)
        }
    }

    func notifyNotchExperienceDismiss(bundleIdentifier: String, experienceID: String) {
        deliver(to: bundleIdentifier) { client in
            client.notchExperienceDidDismiss(experienceID: experienceID)
        }
    }

    nonisolated private static func resolvePeerIdentity(
        for connection: NSXPCConnection
    ) -> ExtensionXPCPeerIdentity? {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 0,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        let guestAttributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier)
        ] as CFDictionary

        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, guestAttributes, [], &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(dynamicCode, [], nil) == errSecSuccess else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &signingInformation) == errSecSuccess,
              let signingValues = signingInformation as? [CFString: Any],
              let signingIdentifier = signingValues[kSecCodeInfoIdentifier] as? String,
              signingIdentifier == bundleIdentifier else {
            return nil
        }

        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &designatedRequirement) == errSecSuccess,
              let designatedRequirement else {
            return nil
        }

        var requirementText: CFString?
        guard SecRequirementCopyString(designatedRequirement, [], &requirementText) == errSecSuccess,
              let requirementText else {
            return nil
        }

        return ExtensionXPCPeerIdentity(
            bundleIdentifier: bundleIdentifier,
            codeSigningRequirement: requirementText as String,
            applicationPath: application.bundleURL?.path
        )
    }

    private func deliver(
        to bundleIdentifier: String,
        requiresAuthorizedIdentity: Bool = true,
        send block: (AtollXPCClientProtocol) -> Void
    ) {
        for (_, context) in clientContexts where context.bundleIdentifier == bundleIdentifier {
            if requiresAuthorizedIdentity,
               !ExtensionAuthorizationManager.shared.isXPCIdentityAuthorized(
                bundleIdentifier: bundleIdentifier,
                codeSigningRequirement: context.codeSigningRequirement
               ) {
                continue
            }

            let connection = context.connection

            guard let client = connection.remoteObjectProxyWithErrorHandler({ error in
                Logger.log("Failed to deliver XPC callback to \(bundleIdentifier): \(error)", category: .extensions)
            }) as? AtollXPCClientProtocol else {
                continue
            }

            block(client)
        }
    }

    private func removeConnection(_ connection: NSXPCConnection) {
        clientContexts.removeValue(forKey: ObjectIdentifier(connection))
        Logger.log("Removed XPC connection", category: .extensions)
    }
}
