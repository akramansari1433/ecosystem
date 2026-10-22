# Ecosystem

Make an Android phone and a Mac work together the way an iPhone does — over your own
Wi-Fi, with no cloud, no account, and no cable.

Copy on one device and paste on the other. See the phone's notifications on the Mac
and reply from there. Answer or decline calls from the Mac. Browse the phone's photos
and files in a window. Use the phone's cameras from the Mac. Ring the phone when it's
lost in the sofa.

Everything happens directly between the two devices on your local network. Nothing is
uploaded anywhere, ever.

## What works

| Feature | |
|---|---|
| Finds your phone and connects on its own — even after a phone restart | ✅ |
| Pair by scanning a QR code (or comparing a 6-digit code) | ✅ |
| Works with more than one Mac — and ignores other people's phones | ✅ |
| Clipboard sync, both directions, automatic | ✅ |
| Steps aside for payment apps automatically (they dislike accessibility services) | ✅ |
| Phone notifications on the Mac — reply, act, dismiss, or silence them | ✅ |
| Answer or decline phone calls from the Mac | ✅ |
| Ring my phone — loud even on silent | ✅ |
| Browse, download and upload phone files, with previews and drag-out | ✅ |
| See through the phone's cameras in a window, all lenses | ✅ |
| Phone camera as a webcam in Zoom/Meet/FaceTime | planned |

Built and tested with a Samsung phone (One UI, Android 12+) and Apple Silicon Macs.
Other Android phones should work; the clipboard and battery workarounds are written
for Samsung quirks.

## What it deliberately doesn't do

Honesty section. These aren't bugs — they're walls Android and macOS put up:

- **Talking through the Mac's mic and speakers during a phone call.** Android only
  lets the manufacturer's own system apps touch call audio. You can answer/decline
  from the Mac, and the phone flips to speakerphone, but the voice goes through the
  phone.
- **Screen mirroring.** It was built — video, audio, full remote control — and then
  removed. Android can't capture a switched-off screen or skip the per-boot consent
  tap, so it could never feel like iPhone Mirroring, and a half-version isn't worth
  its complexity. The code lives in git history if you want it back.

## Install

Ready-to-install builds are in [`dist/`](dist), rebuilt whenever a feature changes:

- **Mac** — open `dist/Ecosystem.dmg`, drag Ecosystem to Applications. First launch:
  right-click the app → Open (it isn't registered with Apple, which costs $99/year).
  It lives in the menu bar, not the Dock.
- **Phone** — copy `dist/Ecosystem.apk` to the phone and tap it, allowing installs
  from unknown sources.

Then open the phone app, grant the permissions it asks for (each one has a card
explaining what it unlocks), and pair: click the menu-bar icon on the Mac →
**Pair by scanning…** → point the phone's scanner at the QR code. Done.

Full walkthrough, including the Samsung battery settings that keep the connection
alive: **[docs/BUILDING.md](docs/BUILDING.md)**.

## Build it yourself

```bash
git clone https://github.com/akramansari1433/ecosystem.git
cd ecosystem
scripts/release.sh      # builds both apps into dist/
```

Requires Xcode, plus `brew install xcodegen openjdk@21` and
`brew install --cask android-commandlinetools`. See
[docs/BUILDING.md](docs/BUILDING.md) for the details and for installing to the phone
over USB or Wi-Fi while developing.

## How it works

The phone announces itself on your Wi-Fi; the Mac finds it and connects. Pairing gives
both devices a shared secret, and after that every connection is encrypted and
authenticated — nobody else on the network can connect, even someone who was watching
during pairing.

**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** explains the whole system — in plain
English first, then in technical detail with diagrams.
**[docs/protocol.md](docs/protocol.md)** is the exact message format the two apps
speak, if you want to build something compatible.

## Layout

```
mac-app/       macOS menu-bar app (Swift, SwiftUI)
android-app/   Android companion app (Kotlin)
docs/          how it works, how to build, the wire protocol
scripts/       build and packaging
dist/          the latest built apps
```

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, learn from it.
