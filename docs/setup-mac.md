# Mac setup

## Build & run

```bash
cd mac-app
xcodegen                      # regenerate the Xcode project after adding files
xcodebuild -project Ecosystem.xcodeproj -scheme Ecosystem -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Ecosystem-*/Build/Products/Debug/Ecosystem.app
```

Or open `mac-app/Ecosystem.xcodeproj` in Xcode and hit Run. M1–M3 use ad-hoc
signing ("Sign to Run Locally") — no Apple ID required until the webcam milestone.

## Permissions

- **Local Network**: on first launch macOS asks "Ecosystem would like to find and
  connect to devices on your local network" — click **Allow**. If you declined:
  System Settings → Privacy & Security → Local Network → enable Ecosystem.
  Without it, discovery fails silently.
- **Keychain**: after a rebuild the app may ask to access its own private key
  ("Ecosystem wants to use your confidential information") — click **Always Allow**.

## Pairing

1. Install and open the app on the phone (see setup-android.md).
2. Click the Ecosystem menu-bar icon → **Pair with this phone…**
3. Accept on the phone, verify both devices show the SAME 6-digit code, confirm on both.
4. Status flips to "Connected" a moment later — clipboard sync and Ring are live.

To unpair: delete `~/Library/Application Support/Ecosystem/paired-peer.der` (Mac)
and clear app data (phone), then pair again.
