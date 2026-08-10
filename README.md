# Ecosystem

Personal "Continuity for Android": connect a Samsung Android phone and a Mac over the
same Wi-Fi network — no cables, no cloud.

## Features

| Feature | Status |
|---|---|
| Auto-discovery + one-time pairing (TLS, pinned certs) | ✅ |
| Clipboard sync (both directions) | ✅ automatic |
| Ring my phone | ✅ |
| Browse phone files from the Mac | 🚧 M2 |
| Screen mirroring in a Mac window | ⏳ M3 |
| Phone camera as a real system webcam (Zoom/Meet/FaceTime) | ⏳ M4 |

## Layout

- `mac-app/` — native Swift menu-bar app (macOS 26, Xcode)
- `android-app/` — Kotlin companion app (minSdk 31, Gradle)
- `docs/protocol.md` — the wire contract; single source of truth
- `protocol/test-vectors/` — golden fixtures asserted by BOTH test suites

## One-time phone setup (Samsung)

1. Install the APK: `cd android-app && ./gradlew installDebug` (phone on USB once, or sideload).
2. Settings → Apps → Ecosystem → Battery → **Unrestricted**.
3. Settings → Device care → remove Ecosystem from "sleeping apps".
4. Grant the Accessibility permission when prompted (needed for phone→Mac clipboard).

## Building

- Mac: open `mac-app/Ecosystem.xcodeproj`, or `cd mac-app && xcodegen && xcodebuild`.
- Android: `cd android-app && ./gradlew assembleDebug`.
