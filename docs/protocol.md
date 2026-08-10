# Ecosystem Wire Protocol — v1

Single source of truth for the Android ↔ Mac protocol. Both codebases and both test
suites must match this document exactly. Golden fixtures live in `../protocol/test-vectors/`.

## 1. Roles and connections

- **Android = server.** Advertises `_ecosys._tcp` via mDNS. TXT record keys:
  `deviceId` (UUID string), `name` (human-readable), `protocolVersion` (int as string).
  Runs a TLS server socket on an ephemeral port published in the mDNS record.
- **Mac = client.** Discovers via Bonjour, dials. Opens:
  - exactly one persistent **control connection**, and
  - zero or more **stream connections** (file transfer, video), each dialing the same
    port and immediately sending `stream.attach`.

TLS: both sides use long-lived self-signed P-256 certificates. Before pairing, peers
accept any certificate but capture the leaf. After pairing, both sides require an
exact DER byte match of the pinned peer certificate.

## 2. Framing

### 2.1 Control connection (JSON frames)

```
[uint32 big-endian length][UTF-8 JSON payload of that length]
```

Max frame: 1 MiB (1,048,576 bytes). A peer receiving a larger declared length MUST
close the connection.

### 2.2 Stream connections (binary frames, after attach)

The first frame on a stream connection is a JSON frame (§2.1) whose message type is
`stream.attach`. Every frame after that is binary:

```
[uint32 BE length][uint8 frameType][int64 BE ptsMicros][payload of (length - 9) bytes]
```

`length` counts frameType + ptsMicros + payload. Frame types:

| value | meaning |
|---|---|
| 0 | codec-config (H.264 SPS+PPS, Annex-B) |
| 1 | video keyframe (Annex-B) |
| 2 | video delta frame (Annex-B) |
| 3 | file chunk |
| 4 | end of stream |

`ptsMicros` is presentation time for video frames; byte offset for file chunks; 0 for
codec-config and end frames.

## 3. Message envelope

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "type": "clipboard.set",
  "replyTo": "…",
  "payload": { }
}
```

- `id`: UUID v4, unique per message.
- `type`: namespaced, dot-separated.
- `replyTo`: present only on responses; echoes the request `id`.
- `payload`: type-specific object; omitted when empty.

Canonical JSON encoding (used by encoders and asserted byte-exact by fixtures): no
extra whitespace, **all object keys sorted alphabetically at every nesting level**,
no forward-slash escaping, non-ASCII emitted as raw UTF-8 (no `\uXXXX`), absent
optional fields omitted entirely (never `null`). Parsers MUST accept any key order.

## 4. Session messages

**The client (Mac) speaks first on every connection.** Its first frame declares the
connection's purpose: `hello` makes it the control connection (the server replies
with its own `hello`); `stream.attach` makes it a stream connection (the server
replies nothing and switches to binary framing).

| type | direction | payload |
|---|---|---|
| `hello` | both, first message after connect | `{ deviceId, name, protocolVersion, capabilities }` |
| `ping` | both, every 10 s idle | — |
| `pong` | reply | — |
| `error` | both | `{ code, message? }` |

- `protocolVersion`: integer, currently `1`. On mismatch, send
  `error { code: "version_mismatch" }` and close.
- `capabilities`: array of strings from `["clipboard","ring","fs","mirror","camera"]`.
- Dead peer: no frame for 30 s → close and (Mac) reconnect with backoff.

## 5. Pairing (TOFU + verification code)

States: `idle → requested → codeDisplayed → confirmedLocal → paired | failed`.

1. Mac (unpaired) connects, sends `hello`, then `pair.request { certFingerprint }`
   where `certFingerprint` = lowercase hex SHA-256 of the Mac's leaf cert DER.
2. Android shows accept/reject UI → `pair.accept` or `pair.reject`.
3. On accept, **both sides independently compute the verification code**:
   `code = uint24(first 3 bytes of SHA-256(concat(sorted([DER_A, DER_B])))) mod 1000000`,
   rendered as a zero-padded 6-digit decimal string. `sorted` = lexicographic byte
   order of the two DER blobs, smaller first.
4. Both display the code. User confirms on each device → each sends `pair.confirm`.
5. After sending AND receiving `pair.confirm`, each side persists the peer cert and
   the connection is closed. Subsequent connections are pinned.
6. Any party may send `pair.abort { reason? }` at any point → state `failed`.

| type | payload |
|---|---|
| `pair.request` | `{ certFingerprint }` |
| `pair.accept` | — |
| `pair.reject` | — |
| `pair.confirm` | — |
| `pair.abort` | `{ reason? }` |

## 6. Clipboard

| type | direction | payload |
|---|---|---|
| `clipboard.set` | both | `{ text, tsMillis }` |

- Text-only in v1.
- Receiver applies **last-writer-wins** on `tsMillis`.
- Echo suppression: each side remembers the SHA-256 of the last clipboard content it
  received and does not send it back.

## 7. Ring

| type | direction | payload |
|---|---|---|
| `ring.start` | Mac → phone | — |
| `ring.stop` | Mac → phone | — |
| `ring.stopped` | phone → Mac | — (sent when ringing ends for any reason) |

## 8. Files (M2)

| type | direction | payload |
|---|---|---|
| `fs.list` | Mac → phone | `{ path }` |
| `fs.entries` | reply | `{ entries: [{ name, isDir, size, mtimeMillis }] }` |
| `fs.download` | Mac → phone | `{ path }` |
| `fs.upload` | Mac → phone | `{ destPath, size }` |
| `fs.transferReady` | reply | `{ token, size? }` |
| `fs.transferResult` | both | `{ token, ok, sha256?, message? }` |

- Paths are absolute within the exposed root (`/storage/emulated/0`); the server
  MUST canonicalize and reject any path escaping the root.
- Transfers run on a stream connection: Mac dials, sends
  `stream.attach { token, kind: "file" }`, then frameType 3 chunks (≤ 256 KiB payload
  each, `ptsMicros` = byte offset) flow (download: phone→Mac; upload: Mac→phone),
  terminated by frameType 4. Receiver verifies SHA-256 and reports `fs.transferResult`.

## 9. Streams

| type | payload |
|---|---|
| `stream.attach` | `{ token, kind: "file" \| "mirror" \| "camera" }` |

`token`: opaque string issued by the phone in `fs.transferReady` / `mirror.started` /
`camera.started`. Unknown or reused token → close connection.

## 10. Mirroring (M3)

| type | direction | payload |
|---|---|---|
| `mirror.start` | Mac → phone | `{ maxLongEdge, bitrateBps }` |
| `mirror.needsConsent` | reply | — (phone surfaces the MediaProjection dialog) |
| `mirror.started` | reply | `{ token, width, height, rotationDeg }` |
| `mirror.stop` | both | — |
| `mirror.rotated` | phone → Mac | `{ width, height, rotationDeg }` |

Video flows on a stream connection (`kind: "mirror"`): frameType 0 config, then 1/2
frames. Phone resends config before every keyframe.

## 11. Camera (M4)

| type | direction | payload |
|---|---|---|
| `camera.start` | Mac → phone | `{ lens: "back"\|"front", width, height, fps }` |
| `camera.started` | reply | `{ token, width, height }` |
| `camera.switchLens` | Mac → phone | `{ lens }` |
| `camera.stop` | both | — |

Same stream framing as mirroring (`kind: "camera"`).

## Versioning

`protocolVersion` is a single integer bumped on any breaking change. No compatibility
matrix — both ends are upgraded together (single phone, single Mac).
