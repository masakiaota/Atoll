# Atoll local RPC protocol (AtollRPC/2)

AtollRPC/2 is the only authenticated protocol accepted by the loopback WebSocket listener at `ws://127.0.0.1:9020`. It replaces the former scheme that sent `authenticationToken` in clear JSON. Old clients must be updated; Atoll deliberately rejects raw tokens on the wire.

The design assumes that another process on the same Mac may bind port 9020 first and relay traffic. Such a relay can still deny service or observe message sizes and timing, but it cannot learn the token or application payload, forge frames, or replay a frame in another position.

## Values and encodings

- `bundleIdentifier`: the authorized client bundle ID, encoded as UTF-8.
- `token`: the 64 lowercase hexadecimal characters copied from Atoll Settings. Decode it to exactly 32 bytes before using it as key material.
- `clientNonce` and `serverNonce`: exactly 32 random bytes, represented as canonical padded standard Base64 in JSON.
- `sessionIdentifier`: the lowercase UUID string returned by Atoll. Use the returned UTF-8 bytes exactly as received.
- Proofs and sealed payloads: canonical padded standard Base64.
- `sequence`: an unsigned 64-bit integer represented as its canonical decimal JSON string. Each direction starts at `"1"`.

Cryptographic operations use SHA-256, HMAC-SHA256, HKDF-SHA256, and ChaCha20-Poly1305.

The protocol uses one unambiguous byte framing function:

```text
frame(domain, fields) =
  UTF8(domain) || 0x00 ||
  for each field: UInt32BE(field.byteCount) || field
```

No Unicode normalization, case folding, JSON canonicalization, or terminating NUL is applied to a field.

## Authorization request

An app that is not yet approved may send this one plaintext JSON-RPC request. Atoll records or refreshes a pending entry, replies, and closes the connection.

```json
{
  "jsonrpc": "2.0",
  "method": "atoll.requestAuthorization",
  "params": {
    "bundleIdentifier": "com.example.my-extension",
    "appName": "My Extension"
  },
  "id": "authorize-1"
}
```

This request must not contain the token. The user approves the pending app in Atoll Settings and supplies its app-specific token to the intended client through a separate local setup step.

## Mutual-proof handshake

Open a new WebSocket and generate a fresh `clientNonce` for every attempt.

1. Send `atoll.secure.begin` in plaintext:

```json
{
  "jsonrpc": "2.0",
  "method": "atoll.secure.begin",
  "params": {
    "bundleIdentifier": "com.example.my-extension",
    "clientNonce": "<32-byte Base64>"
  },
  "id": "begin-1"
}
```

2. Atoll returns `protocolVersion`, `sessionIdentifier`, `serverNonce`, `serverProof`, and `expiresInSeconds`. Require `protocolVersion == 2`; otherwise close the connection without sending a proof. The challenge is bound to this connection, is valid for about 15 seconds, and permits one completion attempt.

3. Construct:

```text
transcript = frame(
  "AtollRPC/2/handshake",
  [UTF8(bundleIdentifier), UTF8(sessionIdentifier), clientNonce, serverNonce]
)

serverProofData = frame("AtollRPC/2/server-proof", [transcript])
expectedServerProof = HMAC-SHA256(key: token, data: serverProofData)
```

Compare `expectedServerProof` and the decoded `serverProof` in constant time. Close the connection without sending a client proof if they differ.

4. Compute:

```text
clientProofData = frame("AtollRPC/2/client-proof", [transcript])
clientProof = HMAC-SHA256(key: token, data: clientProofData)
```

Then send:

```json
{
  "jsonrpc": "2.0",
  "method": "atoll.secure.complete",
  "params": {
    "bundleIdentifier": "com.example.my-extension",
    "sessionIdentifier": "<returned sessionIdentifier>",
    "clientProof": "<32-byte Base64>"
  },
  "id": "complete-1"
}
```

Atoll replies to this handshake request in plaintext. Require `secure == true` and `protocolVersion == 2` before entering the secure state. Every subsequent request, response, and notification on the connection is an encrypted envelope. A client must never treat any later plaintext message as valid.

## Session keys

Derive two independent 32-byte keys:

```text
salt = SHA256(frame("AtollRPC/2/session-salt", [transcript]))

clientToServerKey = HKDF-SHA256(
  inputKeyMaterial: token,
  salt: salt,
  info: frame("AtollRPC/2/client-to-server-key", [transcript]),
  outputByteCount: 32
)

serverToClientKey = HKDF-SHA256(
  inputKeyMaterial: token,
  salt: salt,
  info: frame("AtollRPC/2/server-to-client-key", [transcript]),
  outputByteCount: 32
)
```

The separate keys and direction-specific additional authenticated data prevent a ciphertext from being reflected into the opposite direction.

## Encrypted frames

The plaintext of an encrypted application frame is the complete UTF-8 JSON-RPC request, response, or notification. For a frame with sequence `n`, construct eight-byte big-endian `UInt64BE(n)` and:

```text
client request AAD = frame(
  "AtollRPC/2/client-to-server-frame",
  [UTF8(bundleIdentifier), UTF8(sessionIdentifier), UInt64BE(n)]
)

server message AAD = frame(
  "AtollRPC/2/server-to-client-frame",
  [UTF8(bundleIdentifier), UTF8(sessionIdentifier), UInt64BE(n)]
)
```

Seal the plaintext with ChaCha20-Poly1305 using the matching direction key, a fresh random 96-bit nonce, and that AAD. `sealedPayload` is standard Base64 of:

```text
nonce (12 bytes) || ciphertext || authentication tag (16 bytes)
```

Send the resulting WebSocket text message:

```json
{
  "version": 2,
  "sequence": "1",
  "sealedPayload": "<Base64 nonce+ciphertext+tag>"
}
```

Maintain independent receive and send counters. Accept only the exact next sequence and increment it only after successful authentication. On a missing, repeated, skipped, non-canonical, or unauthentic frame, close the connection and start a new handshake; do not retry a sequence within the same session.

## Deterministic handshake test vector

Use these values to verify a client implementation. Byte ranges are inclusive at the start and exclusive at the end.

```text
token bytes        = 00 01 02 ... 1f
clientNonce bytes  = 20 21 22 ... 3f
serverNonce bytes  = 40 41 42 ... 5f
bundleIdentifier   = com.example.atoll-test
sessionIdentifier  = 01234567-89ab-cdef-0123-456789abcdef

transcript Base64  = QXRvbGxSUEMvMi9oYW5kc2hha2UAAAAAFmNvbS5leGFtcGxlLmF0b2xsLXRlc3QAAAAkMDEyMzQ1NjctODlhYi1jZGVmLTAxMjMtNDU2Nzg5YWJjZGVmAAAAICAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/AAAAIEBBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f
serverProof Base64 = QJKfgQ3ubj2z5i30tjL1ecumSkyLis61qtDvfnJLTaI=
clientProof Base64 = yDH81SgB+3XuR/VXcN00z27hWVd5z9KhIh7limrhvPk=

clientToServerKey  = 379a085680da5380277f3f923f653c1c09207971686aac57e9ef350d32157b04
serverToClientKey  = 82b814b0c115e9c02aa3c89853d364a1029a74fa076364286dd8dbf98001d693
```

The following client-to-server frame vector uses that `clientToServerKey`. The fixed nonce is for testing only; production clients must generate a fresh random nonce for every frame.

```text
sequence           = 1
nonce               = 606162636465666768696a6b
plaintext UTF-8     = {"jsonrpc":"2.0","method":"atoll.getVersion","id":"v1"}
AAD Base64          = QXRvbGxSUEMvMi9jbGllbnQtdG8tc2VydmVyLWZyYW1lAAAAABZjb20uZXhhbXBsZS5hdG9sbC10ZXN0AAAAJDAxMjM0NTY3LTg5YWItY2RlZi0wMTIzLTQ1Njc4OWFiY2RlZgAAAAgAAAAAAAAAAQ==
combined Base64     = YGFiY2RlZmdoaWprWoBucBNqxsJOXe/uzmahc3WXp8Ttx/31HdrQfybGC+4k0NFm620rFDvdgYB7gfkETh81mtXpCVlFBTpNAMQbqbh/C29S5k8=
```

## Operational guidance

- Store the token in the client platform's credential store, not source code, logs, command-line arguments, URLs, or ordinary preferences.
- Do not copy the token into `authenticationToken` or any other RPC parameter.
- Generate nonces with the operating system cryptographic random generator.
- Regenerating or deleting a token in Atoll immediately disconnects sessions that used the old token.
- Atoll does not persist extension presentation payloads. After Atoll relaunches, reconnect and resubmit any content that should still be active.
- Treat disconnects and proof failures as authentication failures. Do not silently fall back to the legacy plaintext protocol.
