# Ecosystem — "Continuity for Android": Android ↔ Mac companion app

## Context

Akram wants an iPhone-Continuity-like experience between their Samsung Android phone and Mac, for personal use: both devices on the same Wi-Fi auto-discover and connect, then provide (1) clipboard sync both ways, (2) ring-my-phone, (3) browsing Android files from the Mac, (4) screen mirroring in a Mac window, (5) phone camera as a **real system webcam** selectable in Zoom/Meet/FaceTime.

Decisions confirmed with the user:
- **Fully wireless** (no ADB, no cables): custom Kotlin companion app on the phone + native Swift menu-bar app on the Mac.
- Accepted platform caveats: one Android consent tap per mirroring session; one-time Accessibility permission for phone→Mac clipboard.
- Webcam must be a real system camera → macOS **CMIO Camera Extension** (needs Apple-ID signing; free account works with a 7-day rebuild cycle — see Risks).
- Approach: **custom lightweight protocol, fully native** (no WebRTC, no KDE Connect reuse). mDNS discovery, TLS-pinned sockets, JSON control plane, raw H.264 video streams (scrcpy-style).
- Build order: foundation → files → mirroring → webcam.

Environment (verified): macOS 26.5.2, Xcode 26.6 ✓, `adb` ✓ (homebrew platform-tools). Missing: JDK, Android SDK, Android Studio → installed in Milestone 0. `/Users/akram/Desktop/ecosystem` is empty, not yet a git repo.

## Architecture

- **Android = server**: foreground service advertises `_ecosys._tcp` via `NsdManager`, runs a TLS `SSLServerSocket` (port published in the mDNS record).
- **Mac = client**: `NWBrowser` discovers, `NWConnection` dials. One persistent **control connection** (length-prefixed JSON envelopes, 1 MiB max frame) + short-lived **stream connections** for files/video that attach with a token, then switch to binary framing `[len][frameType][ptsMicros][payload]` (frameType: codec-config / keyframe / delta / file-chunk / end).
- **Pairing = TOFU + verification code** (KDE Connect style): each side generates a P-256 self-signed cert (Mac: Keychain; Android: BouncyCastle → PKCS#12 in filesDir). On `pair.request`, both display a 6-digit code derived from `SHA-256(sortedConcat(certA_DER, certB_DER))`; user confirms on both; certs pinned (exact DER match) thereafter.
- **Message envelope**: `{id, type, replyTo?, payload?}` — types namespaced per feature: `hello/ping`, `pair.*`, `clipboard.set`, `ring.*`, `fs.*`, `stream.attach`, `mirror.*`, `camera.*`. Single-integer `protocolVersion` in `hello`; hard-fail on mismatch (YAGNI: single phone + single Mac).
- **Video**: Android `MediaProjection`/Camera2 → hardware `MediaCodec` H.264 → stream → Mac `AVSampleBufferDisplayLayer` (mirroring window) or `VTDecompressionSession` → `CVPixelBuffer` → CMIO sink stream (webcam).

## Repository layout (monorepo)

```
ecosystem/
├── README.md, .gitignore
├── docs/            protocol.md (wire contract, source of truth), pairing.md, setup-android.md, setup-mac.md
├── protocol/test-vectors/   envelope.json, pairing-codes.json  ← golden fixtures asserted by BOTH test suites
├── mac-app/         Ecosystem.xcodeproj
│   ├── Ecosystem/   Core/ (ProtocolCodec, Messages, Identity, PairingEngine, DeviceBrowser,
│   │                ControlConnection [actor], StreamConnection), Features/ (ClipboardSync, RingPhone,
│   │                FileBrowser/, Mirroring/, Webcam/), UI/
│   ├── CameraExtension/     CMIOExtension target (M4)
│   └── EcosystemTests/
└── android-app/     Gradle wrapper committed; app/src/main/kotlin/com/akram/ecosystem/
                     core/ (ProtocolCodec, Messages, PairingEngine, Identity, TlsServer),
                     service/ (ConnectionService FGS, NsdAdvertiser), features/ (ClipboardHandler,
                     RingPlayer, FileService, MirrorEncoder, CameraStreamer),
                     accessibility/ClipboardAccessibilityService.kt, ui/ (single Activity) + test/kotlin/
```

No code can be shared across Swift/Kotlin → `docs/protocol.md` + `protocol/test-vectors/` ARE the sharing mechanism; both platforms' unit tests assert byte-exact fixtures to catch codec drift.

## Milestones

### M0 — Toolchain + skeletons
- `git init`, .gitignore, README skeleton, `docs/protocol.md` header.
- Install Android toolchain: `brew install --cask android-studio temurin@21` (recommended — needed later for logcat/MediaCodec debugging; still build via `./gradlew`). Android config: Kotlin 2.x, AGP 8.13+, kotlinx-serialization, coroutines, BouncyCastle bcpkix; minSdk 31, targetSdk 35.
- Both skeletons compile: hello-world `MenuBarExtra` app (signed "Sign to Run Locally" — no Apple ID needed until M4); empty Android app installs via `./gradlew installDebug`.

### M1 — Foundation: discovery, pairing, clipboard, ring
1. Write `docs/protocol.md` v1 (envelope, framing, pairing, clipboard, ring) before code.
2. **TDD units, both platforms**: frame reader (partial/coalesced/oversized reads), envelope round-trips vs `envelope.json`; cert fingerprint + 6-digit code vs `pairing-codes.json`; `PairingEngine` pure state machine (`idle → requested → codeDisplayed → confirmedLocal → paired/failed`; inputs = messages + user actions, outputs = effects).
3. Android integration: `ConnectionService` FGS (`connectedDevice` type + `CHANGE_WIFI_MULTICAST_STATE` prerequisite, multicast lock), NsdManager registration (re-register on network callbacks), TLS accept loop, `POST_NOTIFICATIONS`.
4. Mac integration: NWBrowser (`NSBonjourServices=["_ecosys._tcp"]` + `NSLocalNetworkUsageDescription` in Info.plist — browsing fails SILENTLY without them), NWConnection + `sec_protocol_options_set_verify_block` pinning, reconnect with backoff.
5. Pairing UI both sides (code display + confirm), wired to PairingEngine; persist peer cert; pinned reconnect.
6. Clipboard Mac→phone: poll `NSPasteboard.changeCount` (1 s; no notification API exists) → `clipboard.set`; Android `setPrimaryClip` (background WRITE is allowed). Echo-suppression via content hash; last-writer-wins on timestamp.
7. Clipboard phone→Mac: `ClipboardAccessibilityService` (enabled AccessibilityService exempts the app from the Android 10+ background clipboard-read block) + `OnPrimaryClipChangedListener`. Fallback if One UI breaks it: notification-action / share-sheet target.
8. Ring: `MediaPlayer` with `USAGE_ALARM` at max alarm volume + full-screen-intent notification with Stop; `ring.stopped` back to Mac.

### M2 — File browsing
1. Protocol additions (`fs.list/entries`, `fs.download/upload`, `fs.transferReady/Result`, chunked binary frames) + new golden vectors.
2. TDD: transfer engine state machine (256 KiB chunks, progress, SHA-256, cancel) with in-memory sources; **path-traversal guard** (canonical path stays under root).
3. Android: `MANAGE_EXTERNAL_STORAGE` via settings intent (sideloaded personal app — far simpler than SAF), plain `java.io.File` under `/storage/emulated/0`.
4. Mac: StreamConnection attach + transfers with progress; UI window with `Table`, breadcrumbs, Download (→ ~/Downloads) / Upload (`NSOpenPanel`). No drag-drop/thumbnails (YAGNI).

### M3 — Screen mirroring
1. Android: consent via `createScreenCaptureIntent()`; **API 34+ order**: FGS promoted to `mediaProjection` type FIRST → `getMediaProjection` → `registerCallback` (mandatory) → `createVirtualDisplay` onto `MediaCodec` input surface (`COLOR_FormatSurface`, CBR ~8 Mbps, I-frame interval 2 s, low-latency key, `KEY_REPEAT_PREVIOUS_FRAME_AFTER`, long edge scaled to 1280). Drain loop sends csd-0/1 config frames, then keyframes/deltas with PTS. Rotation → rebuild encoder + resend config + `mirror.rotated`.
2. Mac: Annex-B depacketizer → `CMVideoFormatDescriptionCreateFromH264ParameterSets` → AVCC `CMSampleBuffer` → `AVSampleBufferDisplayLayer` in a resizable window. Annex-B→AVCC converter unit-tested with NAL fixtures.
3. UX: menu "Mirror screen" → `mirror.start` → phone shows consent dialog → window opens on `mirror.started`.

### M4 — Camera as system webcam
1. **Signing spike FIRST (highest project risk)**: hello-world CMIOExtension serving a test pattern; host app gets System Extension capability + `OSSystemExtensionRequest` activation; `systemextensionsctl developer on`; free-Apple-ID personal team; approve in System Settings; verify camera appears in Photo Booth/FaceTime. **Do not build video plumbing before this passes.** If free-team activation fails: decide $99 dev account vs stopping at M3.
2. Extension: `CMIOExtensionProviderSource` → device → **source stream** (what apps see; splash frame when idle) + **sink stream** (fed by host app) — Apple's standard sample pattern.
3. Host feeder: CoreMediaIO device enumeration → `CMIOStreamCopyBufferQueue` → enqueue `CMSampleBuffer`s.
4. Decode: `VTDecompressionSession` → NV12 `CVPixelBuffer` → retimed `CMSampleBuffer` → sink (reuses M3 depacketizer).
5. Android: Camera2 (`CameraDevice.createCaptureSession`) targeting the `MediaCodec` input surface directly, 1280×720@30; FGS type `camera` must start while app is foreground; `FLAG_KEEP_SCREEN_ON` during webcam use. Lens-switch message.

## Risks & mitigations
- **Free Apple ID + CMIO extension**: personal-team macOS provisioning profiles expire in ~7 days → weekly Xcode rebuild for the M4 host app (M1–M3 use ad-hoc signing, never expire). Spike de-risks before investment.
- **Samsung battery killing**: document first-run checklist — Battery → Unrestricted; remove from "sleeping apps"; FGS notification + `START_STICKY` + mDNS re-register on network callbacks.
- **Android 14+ FGS type rules**: each type declared in manifest with companion permission; `mediaProjection` only after consent; `camera` only from foreground.
- **MediaProjection token is one-shot**: `mirror.start` when unconsented → `mirror.needsConsent` → app surfaces dialog → proceed on grant.
- **macOS Local Network prompt**: silent failure mode; document reset path (System Settings → Privacy & Security → Local Network).
- **Samsung codec quirks**: SPS/PPS may arrive only in first keyframe — handle both; resend config before every keyframe.
- **Swift 6 strict concurrency**: connection state in an `actor` from day one.

## Verification
- **Automated per milestone**: `xcodebuild test` + `./gradlew test`, both consuming `protocol/test-vectors/` (codec round-trips, framing fuzz, pairing codes, pairing-engine transitions, path-traversal guard, Annex-B→AVCC fixtures).
- **M1 manual**: fresh install → phone in menu ≤5 s → matching 6-digit codes → clipboard both ways (phone side from a third-party app to prove accessibility path) → ring works on silent → Wi-Fi toggle auto-reconnects without re-pair → phone reboot resurrects service → wiping pairing on one side yields clean re-pair prompt.
- **M2 manual**: download >500 MB video, compare `shasum -a 256`; upload visible in Samsung My Files; cancel mid-transfer leaves no corrupt partial.
- **M3 manual**: glass-to-glass latency <300 ms (stopwatch test); rotation follows; 30-min soak (Instruments memory, phone thermals).
- **M4 manual**: splash frame in Photo Booth with webcam off → live feed in Photo Booth + real Zoom meeting → lens switch → Mac reboot keeps extension registered.

## First implementation steps (M0)
1. `git init` in `/Users/akram/Desktop/ecosystem`, commit this design as `docs/superpowers/specs/2026-08-11-ecosystem-design.md` per superpowers convention.
2. Install Android toolchain (Android Studio + Temurin 21 via brew).
3. Scaffold both app skeletons and verify they build/install.
4. Then follow milestones M1→M4 with the writing-plans skill producing a detailed per-task plan for M1.
