# Ecosystem

Make an Android phone and a Mac work together the way an iPhone does — over your own
Wi-Fi, with no cloud, no account, and no cable.

Copy on one device and paste on the other. Browse the phone's photos and files in a
window on the Mac. See the phone's screen and control it with your Mac's trackpad and
keyboard. Ring the phone when it's lost in the sofa.

Built for one Samsung phone and one Mac, kept deliberately simple.

## What works

| Feature | |
|---|---|
| Finds your phone and connects on its own | ✅ |
| One-time pairing with a six-digit code | ✅ |
| Clipboard sync, both directions, automatic | ✅ |
| Ring my phone — loud even on silent | ✅ |
| Browse, download and upload phone files, with previews | ✅ |
| Mirror the phone's screen | ✅ |
| Control the phone: tap, swipe, scroll, type, Back/Home/Recents, volume | ✅ |
| Phone camera as a webcam in Zoom/Meet/FaceTime | planned |

## Install

Ready-to-install builds are in [`dist/`](dist), rebuilt whenever a feature changes:

- **Mac** — open `dist/Ecosystem.dmg`, drag Ecosystem to Applications. First launch:
  right-click the app → Open (it isn't registered with Apple, which costs $99/year).
  It lives in the menu bar, not the Dock.
- **Phone** — copy `dist/Ecosystem.apk` to the phone and tap it, allowing installs
  from unknown sources.

Then open the phone app, grant the three permissions it asks for, and pair: click the
menu-bar icon on the Mac → **Pair with this phone…** → confirm the same six digits on
both screens.

Full walkthrough, including the Samsung battery settings that keep the connection
alive: **[docs/BUILDING.md](docs/BUILDING.md)**.

## Build it yourself

```bash
scripts/release.sh      # builds both apps into dist/
```

Requires Xcode, plus `brew install xcodegen openjdk@21` and
`brew install --cask android-commandlinetools`. See
[docs/BUILDING.md](docs/BUILDING.md) for the details and for installing over USB or
Wi-Fi while developing.

## How it works

The phone announces itself on your Wi-Fi; the Mac finds it and connects. Pairing
exchanges a shared secret, and after that every connection is encrypted and
authenticated, so nobody else on the network can connect.

**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** explains the whole system — in plain
English first, then in technical detail with diagrams.
**[docs/protocol.md](docs/protocol.md)** is the exact message format the two apps speak.

## Layout

```
mac-app/       macOS menu-bar app (Swift, SwiftUI)
android-app/   Android companion app (Kotlin)
docs/          how it works, how to build, the wire protocol
scripts/       build and packaging
dist/          the latest built apps
```
