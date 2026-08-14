# Building and installing Ecosystem

Ecosystem is two apps that talk to each other: one on your Mac, one on your Android
phone. Ready-made builds are in the `dist` folder — if you just want to use the app,
skip to step 3. Steps 1–2 are only for building from source.

A few words used below, in case they're unfamiliar:

- **APK** — the file format for an Android app, like a `.dmg` is for a Mac app.
- **adb** — a command that talks to your phone from your Mac, used to install the app.
- **Terminal** — the Mac app where you type the commands shown here. Press ⌘+Space,
  type "Terminal", press Enter. Then `cd` into the folder where you cloned this
  project.

---

## 1. One-time setup (building from source only)

Install the tools. Copy each line into Terminal and press Enter:

```bash
brew install xcodegen openjdk@21
```

```bash
brew install --cask android-commandlinetools
```

You also need **Xcode** from the Mac App Store (it's large, ~10 GB — this is Apple's
tool for building Mac apps).

Then tell the build where to find those tools:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
```

```bash
echo "sdk.dir=/opt/homebrew/share/android-commandlinetools" > android-app/local.properties
```

The first line only lasts for that Terminal window. To avoid retyping it, add it to
the end of `~/.zshrc`.

---

## 2. Build both apps

From the project folder:

```bash
scripts/package-dmg.sh          # makes the Mac app  → dist/Ecosystem.dmg
```

```bash
scripts/build-apk.sh            # makes the phone app → dist/Ecosystem.apk
```

That's it. Both finished files land in the `dist` folder. The first build takes a few
minutes; later ones are much quicker.

---

## 3. Install the Mac app

Open `dist/Ecosystem.dmg`, then drag **Ecosystem** onto the **Applications** shortcut
inside the window. Open it from Applications (or Spotlight).

macOS will refuse to open it the first time, because the app isn't registered with
Apple — that registration costs $99/year and isn't worth it for a personal app.
To get past it, **right-click the app → Open**, then click **Open** in the dialog.
You only do this once.

Ecosystem has no Dock icon by design: look for the small phone icon in the menu bar at
the top-right of your screen, next to the clock.

Two questions macOS asks at first start, both worth a yes:

- **"Find devices on your local network?" — Allow.** Without it your Mac can never
  see your phone, and it fails silently with no error.
- **"Send you notifications?" — Allow.** This is how your phone's notifications
  appear on the Mac.

---

## 4. Install the phone app

Pick whichever suits you.

**Easiest — no cable, no commands.** Copy `dist/Ecosystem.apk` to your phone (Google
Drive, email to yourself, or a USB cable all work), then tap the file on the phone and
allow installing from unknown sources when asked.

**With a USB cable.** First turn on developer access on the phone: Settings → About
phone → Software information → tap **Build number** seven times, then Settings →
Developer options → turn on **USB debugging**. Plug the phone in, accept the prompt on
its screen, then run:

```bash
adb install -r dist/Ecosystem.apk
```

**Over Wi-Fi, no cable.** Useful if you'll be updating the app often. On the phone:
Developer options → **Wireless debugging** → **Pair device with pairing code**. Leave
that dialog open — it shows a six-digit code and an address — then run (with your own
address and code):

```bash
adb pair 192.168.1.10:34975 493139     # address and code from the pairing dialog
```

```bash
adb connect 192.168.1.10:40101         # address on the main Wireless debugging screen
```

```bash
adb install -r dist/Ecosystem.apk
```

You only pair once; afterwards `adb connect` is enough.

---

## 5. Set up the phone (five minutes, once)

Open **Ecosystem** on the phone and grant these. Each one unlocks a specific feature,
and the app shows a card for anything still missing — nothing breaks if you skip one,
you just lose that feature:

| Permission | What it unlocks |
|---|---|
| **Notifications** | Required — Android insists on a visible notification for an app that stays connected in the background. |
| **Accessibility** ("Ecosystem clipboard sync") | Copying *from* the phone to the Mac, and all remote control: tapping, swiping, typing, Back/Home/Recents. |
| **Notification access** | Your phone's notifications on the Mac — including replying, and answering or declining calls from there. |
| **All files access** | Browsing the phone's files from the Mac. |
| **Microphone** | The phone's *sound* on the Mac while mirroring. Android files "capture what's playing" under the microphone permission — the mic itself is never recorded. |
| **Camera** | Viewing through the phone's cameras from the Mac. |

Then stop Samsung from shutting the app down while the phone is idle:

- Settings → Apps → Ecosystem → Battery → **Unrestricted**
- Settings → Device care → Battery → Background usage limits → make sure Ecosystem is
  **not** in *Sleeping apps* or *Deep sleeping apps*

With that done, the phone reconnects to the Mac by itself — after Wi-Fi drops, after
the app updates, and after the phone restarts.

---

## 6. Pair the two apps

Make sure the phone and Mac are on the **same Wi-Fi**, then pick either method:

**Scan a QR code (easiest).**

1. Click the phone icon in the Mac's menu bar → **Pair by scanning…**. A QR code
   appears.
2. On the phone, open Ecosystem → **Scan QR code from Mac**, and point the camera at
   the Mac's screen.

That's the whole thing — being able to see the Mac's screen is the proof that both
devices are yours. The code expires after a few minutes and each code works once.

**Or compare a 6-digit code.** Click **Pair with a 6-digit code…** on the Mac, tap
**Accept** on the phone, check that both screens show the same six digits, and confirm
on both.

From then on the two find each other automatically whenever they're on the same
Wi-Fi: nothing to open, nothing to re-approve.

**More than one Mac?** Repeat the same pairing on each Mac. The phone lists every
paired Mac and can remove any of them; the Mac's menu has **Forget this phone** (the
small phone-with-a-slash icon next to Quit).

---

## Updating later

After changing the code, rebuild and reinstall:

```bash
scripts/package-dmg.sh && scripts/build-apk.sh
```

For the phone, if you set up USB or Wi-Fi debugging, this one command builds and
installs in a single step:

```bash
cd android-app && ./gradlew installDebug
```

Heads-up: whenever the phone app is reinstalled, One UI silently switches off the
**Accessibility** service (and sometimes **Notification access**). If clipboard,
remote control, or Mac notifications stop after an update, flip those two back on.

---

## If something goes wrong

| What you see | What it means |
|---|---|
| The Mac never finds the phone | Usually the Local Network permission. System Settings → Privacy & Security → Local Network → switch Ecosystem on. Also check both devices are on the same Wi-Fi, not a guest network. |
| Tapping and typing in the mirror window do nothing | Android switched the Accessibility service off, which it does whenever the app is reinstalled. The mirror window shows an orange banner when this happens. Fix: Settings → Accessibility → Ecosystem clipboard sync → off, then on. |
| Phone notifications stopped appearing on the Mac | Same reinstall quirk, other permission: Settings → Notifications → Advanced settings → Notification access → Ecosystem on. Also check macOS allows Ecosystem notifications (System Settings → Notifications). |
| Mirroring has a picture but no sound | The Microphone permission card in the phone app, or the app playing is DRM-protected (Netflix etc. opt out of capture — that's their choice, not fixable). |
| It disconnects when the phone has been idle | Samsung's battery manager. Apply the two battery settings in step 5. |
| It doesn't reconnect after the phone restarts | The app starts itself on boot, but only if Samsung hasn't restricted it — same two battery settings in step 5. |
| macOS says the app "cannot be opened" | Expected on first launch — right-click the app → Open. |
| `Unable to locate a Java Runtime` | The `export JAVA_HOME=…` line from step 1 hasn't been run in this Terminal window. |
| Gradle errors mentioning `InternalProblems` | Something used a system-installed Gradle. Always build with `./gradlew` or the scripts, which use the correct version. |

---

## For developers

- Work on the Mac app in Xcode: `cd mac-app && xcodegen && open Ecosystem.xcodeproj`.
  Re-run `xcodegen` after adding or removing source files — the `.xcodeproj` is
  generated from `project.yml` and isn't committed.
- The Mac app is ad-hoc signed and uses no keychain; its pairing key is a 0600 file in
  `~/Library/Application Support/Ecosystem/`.
- `scripts/build-apk.sh release` produces an unsigned release APK. To install one, add
  a `signingConfigs` block to `android-app/app/build.gradle.kts`; for personal use the
  debug build is simpler and works the same.
- [ARCHITECTURE.md](ARCHITECTURE.md) explains how the pieces fit together;
  [protocol.md](protocol.md) is the exact message format the two apps speak.
