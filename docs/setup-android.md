# Android setup

## Build & install (developer Mac)

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
cd android-app
./gradlew installDebug        # phone connected via USB with USB debugging ON, or:
./gradlew assembleDebug       # then sideload app/build/outputs/apk/debug/app-debug.apk
```

USB debugging is only needed to *install* the app. All features are wireless.

## One-time phone setup (Samsung)

1. Open **Ecosystem** once so its service starts (a persistent notification appears).
2. Allow notifications when prompted.
3. Battery: Settings → Apps → Ecosystem → Battery → **Unrestricted**.
4. Sleeping apps: Settings → Device care → Battery → Background usage limits →
   make sure Ecosystem is NOT in "Sleeping apps" / "Deep sleeping apps".
5. Clipboard phone→Mac — One UI only lets the app in focus read the clipboard
   (Samsung blocks the accessibility exemption stock Android allows), so use any of:
   - **Quick Settings tile**: edit Quick Settings, add **Send clipboard to Mac**.
     Copy → swipe down → tap. A toast confirms "Sent to Mac".
   - **Share menu**: select text → Share → **Send to Mac** (no copy needed).
   - **Open the app**: opening Ecosystem auto-syncs whatever you last copied.
   Mac→phone clipboard is instant and automatic — no setup.

## Troubleshooting

- **Phone never appears on the Mac**: both devices must be on the same Wi-Fi network
  (not the guest VLAN); toggle Wi-Fi off/on to force a re-advertise.
- **Stops working after a while**: re-check steps 3–4 — One UI re-enables battery
  limits after some updates.
