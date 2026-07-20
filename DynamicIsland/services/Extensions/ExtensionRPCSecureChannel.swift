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

import CryptoKit
import Foundation
import Security

/// Cryptographic primitives for the version 2 local RPC channel.
///
/// The WebSocket listener is intentionally loopback-only, but another local
/// process can still bind the public port first. Mutual proofs keep the token
/// off the wire, while direction-separated AEAD keys protect every application
/// frame even when such a process transparently relays the connection.
enum ExtensionRPCSecureChannel {
    static let protocolVersion = 2
    static let nonceByteCount = 32
    static let proofByteCount = 32

    struct SessionKeys {
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
    }

    enum Direction: String {
        case clientToServer = "client-to-server"
        case serverToClient = "server-to-client"
    }

    static func tokenKey(from hexadecimalToken: String) throws -> SymmetricKey {
        let bytes = Array(hexadecimalToken.utf8)
        guard bytes.count == 64 else {
            throw SecureChannelError.invalidToken
        }

        var token = Data()
        token.reserveCapacity(32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexadecimalNibble(bytes[offset]),
                  let low = hexadecimalNibble(bytes[offset + 1]) else {
                throw SecureChannelError.invalidToken
            }
            token.append((high << 4) | low)
        }
        return SymmetricKey(data: token)
    }

    static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SecureChannelError.randomGenerationFailure(status)
        }
        return Data(bytes)
    }

    static func decodeNonce(_ base64: String) throws -> Data {
        try decodeCanonicalBase64(base64, byteCount: nonceByteCount)
    }

    static func decodeProof(_ base64: String) throws -> Data {
        try decodeCanonicalBase64(base64, byteCount: proofByteCount)
    }

    static func transcript(
        bundleIdentifier: String,
        sessionIdentifier: String,
        clientNonce: Data,
        serverNonce: Data
    ) -> Data {
        framed(
            domain: "AtollRPC/2/handshake",
            fields: [
                Data(bundleIdentifier.utf8),
                Data(sessionIdentifier.utf8),
                clientNonce,
                serverNonce
            ]
        )
    }

    static func serverProof(for transcript: Data, using tokenKey: SymmetricKey) -> Data {
        proof(domain: "AtollRPC/2/server-proof", transcript: transcript, using: tokenKey)
    }

    static func verifiesClientProof(
        _ candidate: Data,
        transcript: Data,
        using tokenKey: SymmetricKey
    ) -> Bool {
        let authenticatedData = framed(
            domain: "AtollRPC/2/client-proof",
            fields: [transcript]
        )
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: authenticatedData,
            using: tokenKey
        )
    }

    static func deriveSessionKeys(transcript: Data, tokenKey: SymmetricKey) -> SessionKeys {
        let salt = Data(SHA256.hash(data: framed(
            domain: "AtollRPC/2/session-salt",
            fields: [transcript]
        )))

        return SessionKeys(
            clientToServer: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: tokenKey,
                salt: salt,
                info: framed(domain: "AtollRPC/2/client-to-server-key", fields: [transcript]),
                outputByteCount: 32
            ),
            serverToClient: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: tokenKey,
                salt: salt,
                info: framed(domain: "AtollRPC/2/server-to-client-key", fields: [transcript]),
                outputByteCount: 32
            )
        )
    }

    static func seal(
        _ plaintext: Data,
        sequence: UInt64,
        direction: Direction,
        bundleIdentifier: String,
        sessionIdentifier: String,
        using key: SymmetricKey
    ) throws -> RPCSecureEnvelope {
        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: additionalAuthenticatedData(
                sequence: sequence,
                direction: direction,
                bundleIdentifier: bundleIdentifier,
                sessionIdentifier: sessionIdentifier
            )
        )

        return RPCSecureEnvelope(
            version: protocolVersion,
            sequence: String(sequence),
            sealedPayload: sealedBox.combined.base64EncodedString()
        )
    }

    static func open(
        _ envelope: RPCSecureEnvelope,
        expectedSequence: UInt64,
        direction: Direction,
        bundleIdentifier: String,
        sessionIdentifier: String,
        using key: SymmetricKey
    ) throws -> Data {
        guard envelope.version == protocolVersion,
              let sequence = UInt64(envelope.sequence),
              String(sequence) == envelope.sequence,
              sequence == expectedSequence,
              let combined = Data(base64Encoded: envelope.sealedPayload),
              combined.base64EncodedString() == envelope.sealedPayload else {
            throw SecureChannelError.invalidEnvelope
        }

        let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(
            sealedBox,
            using: key,
            authenticating: additionalAuthenticatedData(
                sequence: sequence,
                direction: direction,
                bundleIdentifier: bundleIdentifier,
                sessionIdentifier: sessionIdentifier
            )
        )
    }

    private static func proof(
        domain: String,
        transcript: Data,
        using tokenKey: SymmetricKey
    ) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: framed(domain: domain, fields: [transcript]),
            using: tokenKey
        ))
    }

    private static func additionalAuthenticatedData(
        sequence: UInt64,
        direction: Direction,
        bundleIdentifier: String,
        sessionIdentifier: String
    ) -> Data {
        var bigEndianSequence = sequence.bigEndian
        let sequenceData = withUnsafeBytes(of: &bigEndianSequence) { Data($0) }
        return framed(
            domain: "AtollRPC/2/\(direction.rawValue)-frame",
            fields: [
                Data(bundleIdentifier.utf8),
                Data(sessionIdentifier.utf8),
                sequenceData
            ]
        )
    }

    /// Encodes every field as a UInt32 big-endian length followed by its bytes.
    /// This format is deliberately simple to reproduce in non-Swift clients.
    private static func framed(domain: String, fields: [Data]) -> Data {
        var output = Data(domain.utf8)
        output.append(0)

        for field in fields {
            precondition(field.count <= Int(UInt32.max))
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(field)
        }
        return output
    }

    private static func decodeCanonicalBase64(_ value: String, byteCount: Int) throws -> Data {
        guard let data = Data(base64Encoded: value),
              data.count == byteCount,
              data.base64EncodedString() == value else {
            throw SecureChannelError.invalidBase64
        }
        return data
    }

    private static func hexadecimalNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 97...102:
            byte - 87
        default:
            nil
        }
    }
}

/// Outer frame used after the mutual-proof handshake. `sequence` is a decimal
/// string so JavaScript and other clients do not lose UInt64 precision.
struct RPCSecureEnvelope: Codable {
    let version: Int
    let sequence: String
    let sealedPayload: String
}

private enum SecureChannelError: Error {
    case invalidToken
    case invalidBase64
    case invalidEnvelope
    case randomGenerationFailure(OSStatus)
}
