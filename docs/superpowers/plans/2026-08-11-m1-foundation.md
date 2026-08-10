# M1 Foundation Implementation Plan (discovery, pairing, clipboard, ring)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phone and Mac auto-discover on the same Wi-Fi, pair once via a 6-digit code over TLS with pinned self-signed certs, then sync clipboard both ways and ring the phone from the Mac.

**Architecture:** Android runs a foreground service advertising `_ecosys._tcp` (NsdManager) and a TLS server socket. The Mac menu-bar app browses (NWBrowser), dials (NWConnection), and keeps one control connection of length-prefixed JSON frames. Pairing is TOFU + a verification code derived from both certs' DER. All pure logic (framing, envelope codec, pairing code, pairing state machine) is TDD'd on both platforms against shared fixtures in `protocol/test-vectors/`.

**Tech Stack:** Swift 6 / SwiftUI / Network.framework / CryptoKit / swift-certificates (SPM); Kotlin 2.2 / coroutines / kotlinx-serialization / BouncyCastle / NsdManager.

**Amendment vs spec:** Mac identity lives in the Keychain (needed anyway to make a `SecIdentity` for TLS); expect a one-time "allow key access" prompt after rebuilds because M1 uses ad-hoc signing.

**Canonical JSON rule (from docs/protocol.md):** encoders emit compact JSON, all keys sorted alphabetically, raw UTF-8, no `\/` escaping, absent fields omitted. Swift: `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`. Kotlin: declare all `@Serializable` fields in alphabetical order + `explicitNulls = false`.

---

## File structure

```
android-app/app/src/main/kotlin/com/akram/ecosystem/
├── core/FrameReader.kt          # length-prefix frame accumulator
├── core/Messages.kt             # sealed Message + payload data classes
├── core/ProtocolCodec.kt        # envelope encode/decode
├── core/PairingCode.kt          # 6-digit code derivation
├── core/PairingEngine.kt        # pure state machine (role: responder)
├── core/Identity.kt             # BC self-signed cert + PKCS12 persistence
├── core/TlsServer.kt            # SSLServerSocket w/ TOFU trust manager
├── service/ConnectionService.kt # FGS: advertise, accept, dispatch
├── service/NsdAdvertiser.kt
├── features/ClipboardHandler.kt
├── features/RingPlayer.kt
├── accessibility/ClipboardAccessibilityService.kt
└── ui/MainActivity.kt           # status + pairing dialog + battery checklist
android-app/app/src/test/kotlin/com/akram/ecosystem/core/   # unit tests (JVM)

mac-app/Ecosystem/
├── Core/FrameReader.swift
├── Core/Messages.swift
├── Core/ProtocolCodec.swift
├── Core/PairingCode.swift
├── Core/PairingEngine.swift     # pure state machine (role: initiator)
├── Core/Identity.swift          # CryptoKit + swift-certificates + Keychain SecIdentity
├── Core/DeviceBrowser.swift     # NWBrowser wrapper
├── Core/ControlConnection.swift # actor: NWConnection + TLS + frames
├── Core/ConnectionManager.swift # discovery→connect→hello→pairing→features
├── Features/ClipboardSync.swift
├── UI/PairingSheet.swift
└── UI/MenuContent.swift         # extend
mac-app/EcosystemTests/          # unit tests
```

Test-vector path: Kotlin tests resolve `../../../../../../protocol/test-vectors` relative to module dir via `System.getProperty("user.dir")`; Swift tests read `TEST_VECTORS_DIR` build setting via `Bundle` env — simplest robust approach on both: copy nothing, read the repo files by walking up from a known anchor (see task code).

---

### Task 1: Kotlin FrameReader (TDD)

**Files:** Create `core/FrameReader.kt`, test `core/FrameReaderTest.kt`.

- [ ] Write failing tests: single frame, frame split across appends byte-by-byte, two frames coalesced in one append, oversized frame throws.
- [ ] `./gradlew :app:testDebugUnitTest` → fails (class missing).
- [ ] Implement `FrameReader` (internal `ByteArrayOutputStream` buffer; loop: if ≥4 bytes read BE length, reject > 1 MiB, emit payload when complete).
- [ ] Tests pass. Commit `feat(android): protocol frame reader`.

### Task 2: Kotlin Messages + ProtocolCodec (TDD, fixtures)

**Files:** Create `core/Messages.kt`, `core/ProtocolCodec.kt`, test `core/ProtocolCodecTest.kt`.

- [ ] Failing tests: for every case in `envelope.json`, `encodeFrame` reproduces `framedHex` byte-exactly, and `decodeFrame` of the JSON yields the expected typed message; unknown type decodes to `Unknown`; missing payload for typed message throws.
- [ ] Implement: `sealed interface Message` — `Hello(capabilities, deviceId, name, protocolVersion)`, `Ping`, `Pong`, `ErrorMsg(code, message?)`, `PairRequest(certFingerprint)`, `PairAccept`, `PairReject`, `PairConfirm`, `PairAbort(reason?)`, `ClipboardSet(text, tsMillis)`, `RingStart`, `RingStop`, `RingStopped`, `StreamAttach(kind, token)`, `Unknown(type)`. All `@Serializable` payload fields declared alphabetically. `RawEnvelope(id, payload: JsonElement?, replyTo?, type)` — declaration order IS alphabetical. `Json { ignoreUnknownKeys = true; explicitNulls = false }`.
- [ ] Tests pass. Commit `feat(android): envelope codec against golden vectors`.

### Task 3: Kotlin PairingCode (TDD, fixtures)

**Files:** Create `core/PairingCode.kt`, test `core/PairingCodeTest.kt`.

- [ ] Failing test iterates `pairing-codes.json`: `derive(derA, derB) == expectedCode` (hex-decode inputs).
- [ ] Implement: lexicographic byte compare (unsigned!), SHA-256 of concat, first 3 bytes as uint24 `% 1_000_000`, `"%06d"`.
- [ ] Tests pass. Commit.

### Task 4: Kotlin PairingEngine (TDD)

**Files:** Create `core/PairingEngine.kt`, test `core/PairingEngineTest.kt`.

Pure state machine, role **responder**. API:

```kotlin
class PairingEngine(private val role: Role, private val ownDer: ByteArray, private val peerDer: ByteArray) {
    enum class Role { INITIATOR, RESPONDER }
    sealed interface State { /* Idle, Requested, CodeDisplayed, ConfirmedLocal, Paired, Failed(reason) */ }
    sealed interface Input { // Start, ReceivedRequest(fingerprint), ReceivedAccept, ReceivedReject,
                             // ReceivedConfirm, ReceivedAbort(reason?), UserAccepted, UserConfirmed, UserRejected
    }
    sealed interface Effect { // Send(message), ShowAcceptPrompt(fingerprint), DisplayCode(code),
                              // PersistPeerCert, Complete, Fail(reason)
    }
    fun handle(input: Input): List<Effect>  // mutates state, returns effects
}
```

Rules: both `pair.confirm`s (sent AND received) required for `Paired`; receiving confirm before local confirm is remembered; reject/abort from any non-terminal state → `Failed` + `Fail` effect; `DisplayCode` uses `PairingCode.derive(ownDer, peerDer)`; responder's `UserAccepted` emits `Send(PairAccept)` + `DisplayCode`; initiator's `Start` emits `Send(PairRequest(fingerprint))`.

- [ ] Failing tests: full happy path responder; full happy path initiator; confirm-before-local-confirm ordering; reject → Failed; abort mid-flow → Failed; inputs in terminal states are no-ops.
- [ ] Implement. Tests pass. Commit `feat(android): pairing state machine`.

### Task 5: Swift SPM deps + FrameReader (TDD)

**Files:** Modify `mac-app/project.yml` (add `packages: swift-certificates from: 1.0.0`, link to Ecosystem target), create `Core/FrameReader.swift`, test `EcosystemTests/FrameReaderTests.swift`. Regenerate project: `cd mac-app && xcodegen`.

- [ ] Same four failing tests as Task 1 (Swift Testing framework, `#expect`).
- [ ] `xcodebuild test -project Ecosystem.xcodeproj -scheme Ecosystem` → fail, implement, pass, commit `feat(mac): protocol frame reader`.

### Task 6: Swift Messages + ProtocolCodec (TDD, fixtures)

**Files:** Create `Core/Messages.swift`, `Core/ProtocolCodec.swift`, test `EcosystemTests/ProtocolCodecTests.swift`.

- [ ] Failing tests mirror Task 2 exactly, loading `protocol/test-vectors/envelope.json` (locate repo root by walking up from `#filePath`).
- [ ] Implement `enum Message: Equatable` with payload structs; encode via generic `Wrapper<P: Encodable>` using `encodeIfPresent`, `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]`; decode via `Header` pass then typed `Typed<P>` pass; unknown → `.unknown(String)`.
- [ ] Tests pass. Commit.

### Task 7: Swift PairingCode (TDD, fixtures) — mirror Task 3 with CryptoKit SHA256. Commit.

### Task 8: Swift PairingEngine (TDD) — mirror Task 4 (role: initiator exercised, responder still tested). Commit.

### Task 9: Kotlin Identity + TLS plumbing

**Files:** Create `core/Identity.kt`, `core/TlsServer.kt`, test `core/IdentityTest.kt`.

- [ ] Test: fresh `Identity.loadOrCreate(dir)` produces X509Certificate (P-256, ~10y validity, CN=Ecosystem-Android) + parseable again from disk with identical DER.
- [ ] `Identity`: `KeyPairGenerator.getInstance("EC")` 256-bit, BC `JcaX509v3CertificateBuilder` self-signed, persist PKCS12 (`ecosystem.p12`, password constant "ecosystem-local") in `dir`.
- [ ] `TlsServer(identity, pinnedPeerDer: ByteArray?)`: `SSLContext(TLS)` with `KeyManagerFactory` over the keystore and a `X509TrustManager` that (a) unpaired: accepts any client cert but records the leaf; (b) paired: requires exact DER match. `wantClientAuth = true`, TLSv1.3/1.2. Exposes `accept(): Socket-like session + peerDer`.
- [ ] Unit tests for the trust manager DER-match logic (pure). Commit `feat(android): identity + TOFU TLS server`.

### Task 10: Android ConnectionService + NSD + hello/ping

**Files:** Create `service/ConnectionService.kt`, `service/NsdAdvertiser.kt`; modify `AndroidManifest.xml`, `MainActivity.kt`.

- [ ] Manifest: `INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`; `<service android:name=".service.ConnectionService" android:foregroundServiceType="connectedDevice"/>`.
- [ ] `ConnectionService` (START_STICKY): notification channel + FGS start; acquire `MulticastLock`; start `TlsServer` on port 0; `NsdAdvertiser.register(port, deviceId, name, protocolVersion)`; accept loop on `Dispatchers.IO`; per-connection: FrameReader → decode → dispatch; answer `hello`+`ping`; re-register NSD via `ConnectivityManager.NetworkCallback`.
- [ ] `MainActivity`: request `POST_NOTIFICATIONS`, start service, show status via service-bound StateFlow.
- [ ] Manual check: `./gradlew installDebug`; `dns-sd -B _ecosys._tcp` on the Mac shows the phone. Commit `feat(android): advertising foreground service`.

### Task 11: Swift Identity

**Files:** Create `Core/Identity.swift`, test `EcosystemTests/IdentityTests.swift`.

- [ ] Test: `Identity.loadOrCreate()` returns cert DER parseable by swift-certificates, P-256, self-signed, CN=Ecosystem-Mac; second call returns identical DER.
- [ ] Implement with CryptoKit `P256.Signing.PrivateKey` + `Certificate(...)` self-signed builder; store key (kSecClassKey) + cert (kSecClassCertificate) via `SecItemAdd`, fetch `SecIdentity` via `SecIdentityCreateWithCertificate` for TLS. Commit.

### Task 12: Swift DeviceBrowser + ControlConnection + ConnectionManager

**Files:** Create `Core/DeviceBrowser.swift`, `Core/ControlConnection.swift`, `Core/ConnectionManager.swift`; modify `AppState.swift`.

- [ ] `DeviceBrowser`: `NWBrowser(for: .bonjour(type: "_ecosys._tcp", domain: nil))`, publishes results via `AsyncStream`.
- [ ] `ControlConnection` (actor): dial `NWEndpoint` with TLS options — `sec_protocol_options_set_local_identity` (our SecIdentity), `sec_protocol_options_set_verify_block` capturing peer DER (unpaired) or requiring exact match (paired); send/receive framed envelopes; `ping` every 10 s, 30 s dead-peer close.
- [ ] `ConnectionManager` (@MainActor, owns state): browse → dial → exchange `hello` → if unpaired, run PairingEngine (initiator) surfacing effects to UI → on paired, reconnect pinned → maintain reconnect-with-backoff (1,2,4,…30 s cap) while service present.
- [ ] Manual check: with Task 10 running on phone, menu bar shows "Connected to <phone>". Commit `feat(mac): discovery + TLS control connection`.

### Task 13: Pairing UI + persistence, both sides

**Files:** Mac — create `UI/PairingSheet.swift`, modify `ConnectionManager`, `MenuContent.swift`. Android — modify `MainActivity.kt`, `ConnectionService.kt`.

- [ ] Mac: "Pair with <name>…" menu item when unpaired peer found; sheet shows 6-digit code + Confirm/Cancel; effects wired; peer DER persisted to Application Support + reload on launch.
- [ ] Android: incoming `pair.request` → notification tap-through to activity dialog (accept → code display → confirm); peer DER in `filesDir/paired-peer.der`.
- [ ] Manual E2E: pair fresh; verify same code both screens; kill/relaunch both apps — auto-reconnect pinned without UI. Negative: wipe phone-side pairing only → Mac connection refused → Mac shows "Re-pair needed". Commit `feat: pairing flow end-to-end`.

### Task 14: Clipboard Mac→phone

**Files:** Mac — create `Features/ClipboardSync.swift`; Android — create `features/ClipboardHandler.kt`, modify service dispatch.

- [ ] Mac: 1 s timer polling `NSPasteboard.general.changeCount`; on change read `.string`, skip if SHA-256 == last received hash, send `clipboard.set{text, tsMillis: now}`.
- [ ] Android: on `clipboard.set`, `ClipboardManager.setPrimaryClip` (background write allowed), remember hash for echo suppression, apply last-writer-wins by tsMillis.
- [ ] Manual: copy on Mac → paste in any phone app. Commit.

### Task 15: Clipboard phone→Mac (Accessibility)

**Files:** Android — create `accessibility/ClipboardAccessibilityService.kt`, `res/xml/accessibility_config.xml`, manifest service decl (`BIND_ACCESSIBILITY_SERVICE`); MainActivity setup row with deep-link to Accessibility settings. Mac — extend `ClipboardSync` to apply inbound `clipboard.set` to `NSPasteboard` (clear + setString), update last-received hash.

- [ ] Accessibility service registers `OnPrimaryClipChangedListener` on connect; on change reads clip text (exempt while service enabled), hands to ConnectionService via singleton channel; ConnectionService sends `clipboard.set`.
- [ ] Manual: copy in a third-party phone app → ⌘V on Mac. Verify no echo loop (copy same text back and forth stops). Commit.

### Task 16: Ring

**Files:** Android — create `features/RingPlayer.kt`, service dispatch, full-screen-intent notification w/ Stop action (`USE_FULL_SCREEN_INTENT` permission); Mac — "Ring phone" menu item sending `ring.start`, switches to "Stop ringing" until `ring.stopped`.

- [ ] `RingPlayer`: `MediaPlayer` with `AudioAttributes(USAGE_ALARM)`, default alarm ringtone URI, looping; `AudioManager.setStreamVolume(STREAM_ALARM, max)` (restore prior volume on stop); stop via notification action, `ring.stop`, or 60 s timeout → send `ring.stopped`.
- [ ] Manual: phone on silent, screen off → rings loudly; Stop from both sides. Commit.

### Task 17: M1 verification sweep

- [ ] Run full M1 manual checklist from the spec (fresh pair, clipboard both ways incl. third-party app, ring on silent, Wi-Fi toggle reconnect, phone reboot resurrection, one-sided unpair recovery).
- [ ] `xcodebuild test` + `./gradlew test` green.
- [ ] Update README feature table (M1 ✅). Commit `M1 complete`.
