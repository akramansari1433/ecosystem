# Ecosystem

Make an Android phone and a Mac work together the way an iPhone does — over your own
Wi-Fi, with no cloud, no account, and no cable.

Copy on one device and paste on the other. See the phone's notifications on the Mac
and reply from there. Answer or decline calls from the Mac. Browse the phone's photos
and files in a window. Mirror the phone's screen — with its sound playing through the
Mac — and control it with your Mac's trackpad and keyboard. Ring the phone when it's
lost in the sofa.

Everything happens directly between the two devices on your local network. Nothing is
uploaded anywhere, ever.

## What works

| Feature | |
|---|---|
| Finds your phone and connects on its own — even after a phone restart | ✅ |
| Pair by scanning a QR code (or comparing a 6-digit code) | ✅ |
| Works with more than one Mac | ✅ |
| Clipboard sync, both directions, automatic | ✅ |
| Phone notifications on the Mac — reply, act, dismiss from there | ✅ |
| Answer or decline phone calls from the Mac | ✅ |
| Ring my phone — loud even on silent | ✅ |
| Browse, download and upload phone files, with previews and drag-out | ✅ |
| Mirror the phone's screen, with the phone's audio on the Mac | ✅ |
| Control the phone: tap, swipe, scroll, type, Back/Home/Recents, volume | ✅ |
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
- **Mirroring while the phone's screen is off.** Android blocks apps from recording a
  switched-off screen. The **Dim phone** button gets you most of the way: the phone
  stays on but nearly black.
- **Sound from DRM-protected apps.** Netflix and friends opt out of audio capture;
  their picture mirrors, their sound stays on the phone. YouTube, Spotify and games
  come through fine.
- **One "allow" tap after each phone reboot** before the first mirror session —
  Android requires it.

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
