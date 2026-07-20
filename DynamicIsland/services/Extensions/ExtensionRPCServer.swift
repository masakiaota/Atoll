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
import CryptoKit
import Network
import Defaults

/// WebSocket server for Atoll RPC.
/// Uses Apple's Network.framework (`NWListener`) — no external dependencies.
/// Listens on localhost:9020 for JSON-RPC 2.0 requests over WebSocket.
@MainActor
final class ExtensionRPCServer {
    static let shared = ExtensionRPCServer()

    private var listener: NWListener?
    private var connections: [UUID: RPCClientConnection] = [:]
    private var shelfSubscribers: Set<UUID> = []
    private var desiredRunning = false
    private var restartWorkItem: DispatchWorkItem?
    private let port: UInt16 = 9020
    private let maximumMessageSize = 4 * 1024 * 1024
    private let maximumConnectionCount = 32
    private let handshakeLifetime: TimeInterval = 15
    private let queue = DispatchQueue(label: "com.ebullioscopic.Atoll.rpc.server", qos: .userInitiated)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        desiredRunning = true
        restartWorkItem?.cancel()
        restartWorkItem = nil

        guard listener == nil else {
            logDiagnostics("RPC server already running")
            return
        }

        let params = NWParameters(tls: nil)
        params.requiredInterfaceType = .loopback
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = maximumMessageSize
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        } catch {
            Logger.log("Failed to create RPC listener: \(error.localizedDescription)", category: .extensions)
            return
        }

        newListener.newConnectionLimit = maximumConnectionCount
        listener = newListener

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let newListener else { return }
            Task { @MainActor in
                self?.handleListenerState(state, from: newListener)
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        newListener.start(queue: queue)
    }

    func stop() {
        desiredRunning = false
        restartWorkItem?.cancel()
        restartWorkItem = nil

        let activeListener = listener
        listener = nil
        activeListener?.stateUpdateHandler = nil
        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()
        disconnectAllClients()
        logDiagnostics("RPC server stopped")
    }

    func authenticationToken(for bundleIdentifier: String) throws -> String {
        try requireAuthorizedBundleIdentifier(bundleIdentifier)
        return try ExtensionRPCTokenStore.readOrCreateToken(for: bundleIdentifier)
    }

    func regenerateAuthenticationToken(for bundleIdentifier: String) throws -> String {
        try requireAuthorizedBundleIdentifier(bundleIdentifier)
        disconnectClients(for: bundleIdentifier)
        return try ExtensionRPCTokenStore.regenerateToken(for: bundleIdentifier)
    }

    func deleteAuthenticationToken(for bundleIdentifier: String) throws {
        disconnectClients(for: bundleIdentifier)
        try ExtensionRPCTokenStore.deleteToken(for: bundleIdentifier)
    }

    /// Rotates any credential that may have existed before a new authorization
    /// grant. A stale token must never become valid again after re-authorization.
    func prepareAuthenticationForAuthorization(for bundleIdentifier: String) throws {
        disconnectClients(for: bundleIdentifier)
        _ = try ExtensionRPCTokenStore.regenerateToken(for: bundleIdentifier)
    }

    /// Immediately removes all live RPC sessions while a durable revocation is
    /// being committed. This is intentionally independent of Keychain writes.
    func disconnectAuthorizationSessions(for bundleIdentifier: String) {
        disconnectClients(for: bundleIdentifier)
    }

    // MARK: - Client Notifications

    func notifyActivityDismiss(bundleIdentifier: String, activityID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "atoll.activityDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "activityID": .string(activityID)
            ]
        )
    }

    func notifyWidgetDismiss(bundleIdentifier: String, widgetID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "atoll.widgetDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "widgetID": .string(widgetID)
            ]
        )
    }

    func notifyNotchExperienceDismiss(bundleIdentifier: String, experienceID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "atoll.notchExperienceDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "experienceID": .string(experienceID)
            ]
        )
    }

    func notifyAuthorizationChange(bundleIdentifier: String, isAuthorized: Bool) {
        sendNotification(
            to: bundleIdentifier,
            method: "atoll.authorizationDidChange",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "isAuthorized": .bool(isAuthorized)
            ]
        )

        if !isAuthorized {
            let revokedConnectionIDs = connections
                .filter { $0.value.bundleIdentifier == bundleIdentifier }
                .map(\.key)
            shelfSubscribers.subtract(revokedConnectionIDs)
        }
    }

    // MARK: - Shelf Event Subscriptions

    @discardableResult
    func registerShelfSubscription(connectionID: UUID) -> Bool {
        guard let clientConnection = connections[connectionID],
              clientConnection.isAuthenticated,
              let bundleIdentifier = clientConnection.bundleIdentifier,
              isFileSharingAuthorized(for: bundleIdentifier) else {
            shelfSubscribers.remove(connectionID)
            return false
        }

        shelfSubscribers.insert(connectionID)
        logDiagnostics("Registered shelf subscription for \(bundleIdentifier)")
        return true
    }

    func notifyShelfItemsChanged(itemIDs: [String], action: String) {
        guard !shelfSubscribers.isEmpty else { return }
        let params: [String: RPCValue] = [
            "action": .string(action),
            "itemIDs": .array(itemIDs.map { .string($0) })
        ]
        var notificationCount = 0
        let subscriberIDs = shelfSubscribers
        for connectionID in subscriberIDs {
            guard let clientConnection = connections[connectionID],
                  clientConnection.isAuthenticated,
                  let bundleIdentifier = clientConnection.bundleIdentifier,
                  isFileSharingAuthorized(for: bundleIdentifier) else {
                shelfSubscribers.remove(connectionID)
                continue
            }

            sendNotification(
                to: connectionID,
                method: "atoll.shelfItemsDidChange",
                params: params
            )
            notificationCount += 1
        }
        logDiagnostics("Notified \(notificationCount) subscriber(s) of shelf change (\(action), \(itemIDs.count) items)")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State, from sourceListener: NWListener) {
        guard listener === sourceListener else { return }

        switch state {
        case .ready:
            Logger.log("Started Atoll RPC WebSocket server on loopback port \(port)", category: .extensions)
        case .failed(let error):
            Logger.log("RPC server failed: \(error.localizedDescription)", category: .extensions)
            sourceListener.stateUpdateHandler = nil
            sourceListener.newConnectionHandler = nil
            listener = nil
            scheduleRestartIfNeeded()
        case .cancelled:
            logDiagnostics("RPC server listener cancelled")
        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        guard desiredRunning, listener != nil, connections.count < maximumConnectionCount else {
            nwConnection.cancel()
            return
        }

        let connID = UUID()
        let clientConn = RPCClientConnection(
            connection: nwConnection,
            bundleIdentifier: nil,
            handshakeChallenge: nil,
            secureSession: nil
        )
        connections[connID] = clientConn
        updateConnectionLimit()

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(connID: connID, state: state)
            }
        }

        nwConnection.start(queue: queue)
        receiveMessage(connID: connID)
        logDiagnostics("RPC client connected (id: \(connID.uuidString.prefix(8)))")
    }

    private func handleConnectionState(connID: UUID, state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            connections.removeValue(forKey: connID)
            shelfSubscribers.remove(connID)
            updateConnectionLimit()
            logDiagnostics("RPC client disconnected (id: \(connID.uuidString.prefix(8)))")
        default:
            break
        }
    }

    private func receiveMessage(connID: UUID) {
        guard let clientConn = connections[connID] else { return }
        let connection = clientConn.connection

        connection.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.logDiagnostics("RPC receive error for \(connID.uuidString.prefix(8)): \(error.localizedDescription)")
                    self.disconnectClient(connID: connID)
                    return
                }

                guard let data = content, !data.isEmpty else {
                    self.receiveMessage(connID: connID)
                    return
                }

                if await self.processMessage(data: data, connID: connID) {
                    self.receiveMessage(connID: connID)
                }
            }
        }
    }

    private func processMessage(data: Data, connID: UUID) async -> Bool {
        guard let clientConn = connections[connID] else { return false }
        if clientConn.isAuthenticated {
            return await processSecureMessage(data: data, connID: connID)
        }
        return await processHandshakeMessage(data: data, connID: connID)
    }

    private func processHandshakeMessage(data: Data, connID: UUID) async -> Bool {
        guard var clientConn = connections[connID] else { return false }
        guard let request = try? decoder.decode(RPCRequest.self, from: data) else {
            sendHandshakeErrorAndDisconnect(
                code: RPCErrorCode.parseError,
                message: "Invalid JSON-RPC request",
                id: nil,
                connID: connID
            )
            return false
        }

        guard request.jsonrpc == "2.0", !request.method.isEmpty else {
            sendHandshakeErrorAndDisconnect(
                code: RPCErrorCode.invalidRequest,
                message: "Invalid JSON-RPC request",
                id: request.id,
                connID: connID
            )
            return false
        }

        guard request.params?["authenticationToken"] == nil else {
            sendHandshakeErrorAndDisconnect(
                code: RPCErrorCode.unauthorized,
                message: "Raw authentication tokens are not accepted on the wire",
                id: request.id,
                connID: connID
            )
            return false
        }

        guard let bundleIdentifier = request.params?["bundleIdentifier"]?.stringValue,
              isValidBundleIdentifier(bundleIdentifier) else {
            sendHandshakeErrorAndDisconnect(
                code: RPCErrorCode.unauthorized,
                message: "A valid bundleIdentifier is required",
                id: request.id,
                connID: connID
            )
            return false
        }

        let authorizationManager = ExtensionAuthorizationManager.shared
        switch request.method {
        case "atoll.requestAuthorization":
            let authorizationEntry = authorizationManager.authorizationEntry(for: bundleIdentifier)
            guard clientConn.handshakeChallenge == nil,
                  authorizationEntry != nil || authorizationManager.entries.count < 100 else {
                sendHandshakeErrorAndDisconnect(
                    code: RPCErrorCode.unauthorized,
                    message: "Authorization request cannot be accepted",
                    id: request.id,
                    connID: connID
                )
                return false
            }

            let service = ExtensionRPCService(
                bundleIdentifier: bundleIdentifier,
                server: self
            )
            let responseData = await service.handleRequest(request)
            sendRawDataAndDisconnect(responseData, to: connID)
            return false

        case "atoll.secure.begin":
            guard clientConn.handshakeChallenge == nil,
                  authorizationManager.isBundleAuthorized(bundleIdentifier),
                  let clientNonceBase64 = request.params?["clientNonce"]?.stringValue else {
                sendHandshakeErrorAndDisconnect(
                    code: RPCErrorCode.unauthorized,
                    message: "Secure RPC authorization failed",
                    id: request.id,
                    connID: connID
                )
                return false
            }

            do {
                let clientNonce = try ExtensionRPCSecureChannel.decodeNonce(clientNonceBase64)
                let serverNonce = try ExtensionRPCSecureChannel.randomNonce()
                let token = try ExtensionRPCTokenStore.readOrCreateToken(for: bundleIdentifier)
                let tokenKey = try ExtensionRPCSecureChannel.tokenKey(from: token)
                let sessionIdentifier = connID.uuidString.lowercased()
                let transcript = ExtensionRPCSecureChannel.transcript(
                    bundleIdentifier: bundleIdentifier,
                    sessionIdentifier: sessionIdentifier,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce
                )
                let challenge = RPCHandshakeChallenge(
                    bundleIdentifier: bundleIdentifier,
                    sessionIdentifier: sessionIdentifier,
                    transcript: transcript,
                    tokenKey: tokenKey,
                    expiresAtUptime: DispatchTime.now().uptimeNanoseconds
                        + UInt64(handshakeLifetime * 1_000_000_000)
                )

                clientConn.bundleIdentifier = bundleIdentifier
                clientConn.handshakeChallenge = challenge
                connections[connID] = clientConn

                let response = RPCSuccessResponse(
                    result: [
                        "protocolVersion": .int(ExtensionRPCSecureChannel.protocolVersion),
                        "sessionIdentifier": .string(sessionIdentifier),
                        "serverNonce": .string(serverNonce.base64EncodedString()),
                        "serverProof": .string(
                            ExtensionRPCSecureChannel.serverProof(
                                for: transcript,
                                using: tokenKey
                            ).base64EncodedString()
                        ),
                        "expiresInSeconds": .int(Int(handshakeLifetime))
                    ],
                    id: request.id
                )
                sendResponse(response, to: connID)
                scheduleHandshakeExpiry(
                    connID: connID,
                    sessionIdentifier: sessionIdentifier
                )
                return true
            } catch {
                sendHandshakeErrorAndDisconnect(
                    code: RPCErrorCode.unauthorized,
                    message: "Secure RPC authorization failed",
                    id: request.id,
                    connID: connID
                )
                return false
            }

        case "atoll.secure.complete":
            guard let challenge = clientConn.handshakeChallenge,
                  challenge.bundleIdentifier == bundleIdentifier,
                  request.params?["sessionIdentifier"]?.stringValue == challenge.sessionIdentifier,
                  let clientProofBase64 = request.params?["clientProof"]?.stringValue else {
                sendHandshakeErrorAndDisconnect(
                    code: RPCErrorCode.unauthorized,
                    message: "Secure RPC authorization failed",
                    id: request.id,
                    connID: connID
                )
                return false
            }

            // Consume the challenge before parsing or comparing the proof so a
            // failed attempt can never be retried on this connection.
            clientConn.handshakeChallenge = nil
            connections[connID] = clientConn

            do {
                let candidateProof = try ExtensionRPCSecureChannel.decodeProof(clientProofBase64)
                guard DispatchTime.now().uptimeNanoseconds <= challenge.expiresAtUptime,
                      authorizationManager.isBundleAuthorized(bundleIdentifier),
                      ExtensionRPCSecureChannel.verifiesClientProof(
                        candidateProof,
                        transcript: challenge.transcript,
                        using: challenge.tokenKey
                      ) else {
                    throw ExtensionRPCServerError.secureHandshakeFailed
                }

                let sessionKeys = ExtensionRPCSecureChannel.deriveSessionKeys(
                    transcript: challenge.transcript,
                    tokenKey: challenge.tokenKey
                )
                clientConn.secureSession = RPCSecureSession(
                    sessionIdentifier: challenge.sessionIdentifier,
                    keys: sessionKeys,
                    expectedClientSequence: 1,
                    nextServerSequence: 1
                )
                connections[connID] = clientConn

                sendResponse(
                    RPCSuccessResponse(
                        result: [
                            "secure": .bool(true),
                            "protocolVersion": .int(ExtensionRPCSecureChannel.protocolVersion)
                        ],
                        id: request.id
                    ),
                    to: connID
                )
                return true
            } catch {
                sendHandshakeErrorAndDisconnect(
                    code: RPCErrorCode.unauthorized,
                    message: "Secure RPC authorization failed",
                    id: request.id,
                    connID: connID
                )
                return false
            }

        default:
            sendHandshakeErrorAndDisconnect(
                code: RPCErrorCode.unauthorized,
                message: "Complete the secure RPC handshake first",
                id: request.id,
                connID: connID
            )
            return false
        }
    }

    private func processSecureMessage(data: Data, connID: UUID) async -> Bool {
        guard var clientConn = connections[connID],
              var session = clientConn.secureSession,
              let bundleIdentifier = clientConn.bundleIdentifier,
              ExtensionAuthorizationManager.shared.isBundleAuthorized(bundleIdentifier),
              session.expectedClientSequence < UInt64.max,
              let envelope = try? decoder.decode(RPCSecureEnvelope.self, from: data) else {
            disconnectClient(connID: connID)
            return false
        }

        let plaintext: Data
        do {
            plaintext = try ExtensionRPCSecureChannel.open(
                envelope,
                expectedSequence: session.expectedClientSequence,
                direction: .clientToServer,
                bundleIdentifier: bundleIdentifier,
                sessionIdentifier: session.sessionIdentifier,
                using: session.keys.clientToServer
            )
        } catch {
            disconnectClient(connID: connID)
            return false
        }

        session.expectedClientSequence += 1
        clientConn.secureSession = session
        connections[connID] = clientConn

        guard let request = try? decoder.decode(RPCRequest.self, from: plaintext) else {
            let response = RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.parseError, message: "Invalid JSON-RPC request"),
                id: nil
            )
            return sendSecureResponse(response, to: connID)
        }
        guard request.jsonrpc == "2.0", !request.method.isEmpty else {
            let response = RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.invalidRequest, message: "Invalid JSON-RPC request"),
                id: request.id
            )
            return sendSecureResponse(response, to: connID)
        }

        let service = ExtensionRPCService(
            bundleIdentifier: bundleIdentifier,
            server: self,
            connectionID: connID
        )
        let responseData = await service.handleRequest(request)
        return sendSecureRawData(responseData, to: connID)
    }

    private func sendHandshakeErrorAndDisconnect(
        code: Int,
        message: String,
        id: String?,
        connID: UUID
    ) {
        sendResponseAndDisconnect(
            RPCErrorResponse(
                error: RPCErrorObject(code: code, message: message),
                id: id
            ),
            to: connID
        )
    }

    private func scheduleHandshakeExpiry(connID: UUID, sessionIdentifier: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + handshakeLifetime) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard let challenge = self.connections[connID]?.handshakeChallenge,
                      challenge.sessionIdentifier == sessionIdentifier else {
                    return
                }
                self.disconnectClient(connID: connID)
            }
        }
    }

    // MARK: - Send Helpers

    private func sendResponse(_ response: Codable, to connID: UUID) {
        guard let data = try? encoder.encode(response) else { return }
        sendRawData(data, to: connID)
    }

    @discardableResult
    private func sendSecureResponse(_ response: Codable, to connID: UUID) -> Bool {
        guard let data = try? encoder.encode(response) else {
            disconnectClient(connID: connID)
            return false
        }
        return sendSecureRawData(data, to: connID)
    }

    @discardableResult
    private func sendSecureRawData(_ plaintext: Data, to connID: UUID) -> Bool {
        guard var clientConn = connections[connID],
              var session = clientConn.secureSession,
              let bundleIdentifier = clientConn.bundleIdentifier,
              session.nextServerSequence < UInt64.max else {
            disconnectClient(connID: connID)
            return false
        }

        do {
            let envelope = try ExtensionRPCSecureChannel.seal(
                plaintext,
                sequence: session.nextServerSequence,
                direction: .serverToClient,
                bundleIdentifier: bundleIdentifier,
                sessionIdentifier: session.sessionIdentifier,
                using: session.keys.serverToClient
            )
            let data = try encoder.encode(envelope)

            session.nextServerSequence += 1
            clientConn.secureSession = session
            connections[connID] = clientConn
            sendRawData(data, to: connID)
            return true
        } catch {
            disconnectClient(connID: connID)
            return false
        }
    }

    private func sendResponseAndDisconnect(_ response: Codable, to connID: UUID) {
        guard let data = try? encoder.encode(response) else {
            disconnectClient(connID: connID)
            return
        }
        sendRawDataAndDisconnect(data, to: connID)
    }

    private func sendRawDataAndDisconnect(_ data: Data, to connID: UUID) {
        guard let clientConn = connections.removeValue(forKey: connID) else { return }
        shelfSubscribers.remove(connID)
        updateConnectionLimit()
        sendRawData(data, over: clientConn.connection, disconnectAfterSending: true)
    }

    private func sendRawData(_ data: Data, to connID: UUID) {
        guard let clientConn = connections[connID] else { return }

        sendRawData(data, over: clientConn.connection, connID: connID)
    }

    private func sendRawData(
        _ data: Data,
        over connection: NWConnection,
        connID: UUID? = nil,
        disconnectAfterSending: Bool = false
    ) {

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "rpc-response", metadata: [metadata])

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if disconnectAfterSending {
                    connection.cancel()
                }
                if let error {
                    Task { @MainActor in
                        if let connID {
                            self?.disconnectClient(connID: connID)
                        }
                        self?.logDiagnostics("RPC send error: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    private func sendNotification(to bundleIdentifier: String, method: String, params: [String: RPCValue]) {
        let notification = RPCNotification(method: method, params: params)
        guard let data = try? encoder.encode(notification) else { return }

        let connectionIDs = connections
            .filter { $0.value.isAuthenticated && $0.value.bundleIdentifier == bundleIdentifier }
            .map(\.key)
        for connectionID in connectionIDs {
            sendSecureRawData(data, to: connectionID)
        }
    }

    private func sendNotification(to connectionID: UUID, method: String, params: [String: RPCValue]) {
        guard let clientConnection = connections[connectionID],
              clientConnection.isAuthenticated else { return }

        let notification = RPCNotification(method: method, params: params)
        guard let data = try? encoder.encode(notification) else { return }
        sendSecureRawData(data, to: connectionID)
    }

    private func logDiagnostics(_ message: String) {
        guard Defaults[.extensionDiagnosticsLoggingEnabled] else { return }
        Logger.log(message, category: .extensions)
    }

    private func scheduleRestartIfNeeded() {
        restartWorkItem?.cancel()
        guard desiredRunning else {
            restartWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.desiredRunning else { return }
                self.restartWorkItem = nil
                self.start()
            }
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func disconnectAllClients() {
        let activeConnections = connections.values.map(\.connection)
        connections.removeAll()
        shelfSubscribers.removeAll()
        updateConnectionLimit()
        activeConnections.forEach { $0.cancel() }
    }

    private func disconnectClient(connID: UUID) {
        connections.removeValue(forKey: connID)?.connection.cancel()
        shelfSubscribers.remove(connID)
        updateConnectionLimit()
    }

    private func disconnectClients(for bundleIdentifier: String) {
        let matchingConnections = connections
            .filter { $0.value.bundleIdentifier == bundleIdentifier }
            .map(\.key)
        matchingConnections.forEach { disconnectClient(connID: $0) }
    }

    private func updateConnectionLimit() {
        listener?.newConnectionLimit = max(0, maximumConnectionCount - connections.count)
    }

    private func isFileSharingAuthorized(for bundleIdentifier: String) -> Bool {
        ExtensionAuthorizationManager.shared.canProcessFileSharingRequest(from: bundleIdentifier)
    }

    private func isValidBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.utf8.count <= 255 else { return false }

        let components = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }

        return components.allSatisfy { component in
            guard let first = component.utf8.first,
                  let last = component.utf8.last,
                  isASCIIAlphaNumeric(first),
                  isASCIIAlphaNumeric(last) else {
                return false
            }
            return component.utf8.allSatisfy { byte in
                isASCIIAlphaNumeric(byte) || byte == 45 // "-"
            }
        }
    }

    private func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func requireAuthorizedBundleIdentifier(_ bundleIdentifier: String) throws {
        guard isValidBundleIdentifier(bundleIdentifier),
              ExtensionAuthorizationManager.shared.isBundleAuthorized(bundleIdentifier) else {
            throw ExtensionRPCServerError.unauthorizedBundleIdentifier
        }
    }
}

// MARK: - Client Connection

struct RPCClientConnection {
    let connection: NWConnection
    var bundleIdentifier: String?
    var handshakeChallenge: RPCHandshakeChallenge?
    var secureSession: RPCSecureSession?

    var isAuthenticated: Bool {
        secureSession != nil
    }
}

struct RPCHandshakeChallenge {
    let bundleIdentifier: String
    let sessionIdentifier: String
    let transcript: Data
    let tokenKey: SymmetricKey
    let expiresAtUptime: UInt64
}

struct RPCSecureSession {
    let sessionIdentifier: String
    let keys: ExtensionRPCSecureChannel.SessionKeys
    var expectedClientSequence: UInt64
    var nextServerSequence: UInt64
}

private enum ExtensionRPCServerError: LocalizedError {
    case unauthorizedBundleIdentifier
    case secureHandshakeFailed

    var errorDescription: String? {
        switch self {
        case .unauthorizedBundleIdentifier:
            "An authorized extension bundle identifier is required."
        case .secureHandshakeFailed:
            "The secure RPC handshake failed."
        }
    }
}
