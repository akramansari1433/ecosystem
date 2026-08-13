# Ecosystem Wire Protocol — v2

Single source of truth for the Android ↔ Mac protocol. Both apps must match this
document exactly; the Swift and Kotlin codecs are written to be byte-compatible.

## 1. Roles and connections

- **Android = server.** Advertises `_ecosys._tcp` via mDNS. TXT record keys:
  `deviceId` (UUID string), `name` (human-readable), `protocolVersion` (int as string).
  Runs a TLS server socket on an ephemeral port published in the mDNS record.
- **Mac = client.** Discovers via Bonjour, dials. Opens:
  - exactly one persistent **control connection**, and
  - zero or more **stream connections** (file transfer, video), each dialing the same
    port and immediately sending `stream.attach`.

TLS: the phone holds a long-lived self-signed P-256 certificate and presents it as
the server; no client certificate is used. The Mac captures the leaf during pairing
and afterwards requires an exact DER byte match. The Mac proves its own identity at
the application layer (§5.1), which keeps macOS keychains out of the picture.

## 2. Framing

### 2.1 Control connection (JSON frames)

```
[uint32 big-endian length][UTF-8 JSON payload of that length]
```

Max frame: 8 MiB (8,388,608 bytes) — large directory listings and base64 thumbnails
travel on this connection. A peer receiving a larger declared length MUST close the
connection.

Receivers MUST feed bytes to the frame parser in wire order; a single frame often
spans several socket reads.

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

Canonical JSON encoding (both encoders must produce identical bytes): no
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

- `protocolVersion`: integer, currently `2`. On mismatch, send
  `error { code: "version_mismatch" }` and close.
- `capabilities`: strings from `["clipboard","ring","fs","mirror","input"]`. The phone
  advertises `input` only while its accessibility service is connected.
- Dead peer: no frame for 30 s → close and (Mac) reconnect with backoff.

## 5. Pairing (TOFU + verification code)

States: `idle → requested → codeDisplayed → confirmedLocal → paired | failed`.

1. Mac (unpaired) connects, sends `hello`, then `pair.request { certFingerprint }`,
   where the field carries a fresh 32-byte random **nonce** as lowercase hex.
2. Android shows accept/reject UI → `pair.accept` or `pair.reject`.
3. On accept, **both sides independently compute the verification code** from the
   nonce and the phone's certificate:
   `code = uint24(first 3 bytes of SHA-256(concat(sorted([nonce, phoneCertDER])))) mod 1000000`,
   rendered as a zero-padded 6-digit decimal string. `sorted` = lexicographic byte
   order of the two blobs, smaller first.
4. Both display the code. User confirms on each device → each sends `pair.confirm`.
5. After sending AND receiving `pair.confirm`, both derive the shared secret
   `HKDF-SHA256(ikm = nonce, salt = phoneCertDER, info = "ecosystem-auth-v1")` → 32
   bytes, persist it (the Mac also pins the phone's certificate), and the connection
   is closed so the next one runs authenticated.
6. Any party may send `pair.abort { reason? }` at any point → state `failed`.

### 5.1 Per-connection authentication

Once paired, the phone challenges every new control connection and refuses all other
message types until it succeeds.

| type | direction | payload |
|---|---|---|
| `auth.challenge` | phone → Mac | `{ nonce }` (32 random bytes, hex) |
| `auth.response` | Mac → phone | `{ mac }` = hex HMAC-SHA256(secret, nonce) |
| `auth.ok` | phone → Mac | — |

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
| `fs.search` | Mac → phone | `{ path, kinds: ["image"\|"video"], maxDepth }` — recursive; entries carry `relPath` |
| `fs.thumb` | Mac → phone | `{ path, maxEdge }` |
| `fs.thumbData` | reply | `{ dataBase64? }` (JPEG; absent when none could be made) |
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

Video flows on a stream connection (`kind: "mirror"`): frameType 0 config, then 1/2
frames. Phone resends config before every keyframe.

## 11. Notifications

The phone mirrors its notification shade to every connected Mac (needs the
one-time "Notification access" grant on the phone). Buttons — including
Answer/Decline on incoming calls — are pressed remotely by index, and reply
buttons carry the Mac-typed text.

| type | direction | payload |
|---|---|---|
| `notify.posted` | phone → Mac | `{ key, app, pkg, title, text, whenMs, category, clearable, actions: [{ title, reply }] }` — re-posting a `key` replaces it |
| `notify.dismissed` | phone → Mac | `{ key }` (left the phone's shade for any reason) |
| `notify.action` | Mac → phone | `{ key, action, reply? }` — `action` is an index into `actions`; `reply` is inline-reply text |
| `notify.dismiss` | Mac → phone | `{ key }` (the user dismissed the Mac's copy) |

## 12. Input

Coordinates are normalized 0…1 with the origin at the screen's top-left, so they are
independent of resolution and rotation. Requires the phone's accessibility service.

| type | direction | payload |
|---|---|---|
| `input.tap` | Mac → phone | `{ x, y, longPress }` |
| `input.swipe` | Mac → phone | `{ x1, y1, x2, y2, durationMs }` |
| `input.text` | Mac → phone | `{ text }` (typed into the focused field) |
| `input.key` | Mac → phone | `{ key }`: `back`, `home`, `recents`, `notifications`, `lock`, `enter`, `backspace`, `dim.on`, `dim.off` |

## 13. Camera (M4, planned)

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
