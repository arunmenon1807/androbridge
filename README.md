# AndroBridge

[![Build](https://github.com/arunmenon1807/androbridge/actions/workflows/build.yml/badge.svg)](https://github.com/arunmenon1807/androbridge/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

A free, open-source, native macOS file manager for Android phones. Plug in your phone (developed and tested against a Google Pixel) and copy files both ways in a two-pane, Finder-style window.

![AndroBridge: Mac files on the left, phone files on the right, transfers below](docs/images/screenshot.png)

**[⬇ Download the latest DMG](https://github.com/arunmenon1807/androbridge/releases/latest)** · [Install guide](#installing) · [Phone setup](#set-up-your-phone-once) · [Architecture](docs/ARCHITECTURE.md)

- **Native**: Swift + SwiftUI, ~4 MB universal app (Apple Silicon + Intel), macOS 14 Sonoma or later.
- **Private**: no account, no cloud, no analytics, no network traffic except to phones you connect.
- **Safe**: every transfer is written to a hidden temporary item, verified (sizes + SHA-256), then renamed into place. Nothing is overwritten silently; moves only remove the source after the copy is verified; Mac files you delete or replace go to the Trash.

It talks to the phone with Google's **adb** (Android Debug Bridge), over USB or Wi-Fi, so the phone needs USB debugging turned on (a one-time switch; see below). A mode that works without it (MTP) is on the [roadmap](docs/ROADMAP.md).

## What works today

| Area | Status |
| --- | --- |
| Automatic detection of USB phones; reconnects after unplug / adb restart | ✅ |
| Unauthorized / offline / busy device states with on‑screen instructions | ✅ |
| Two‑pane browser (Mac ⟷ phone), breadcrumbs, back/forward/up, list + icon views | ✅ |
| Sort by name/date/size/kind, search the current folder, multi‑select, hidden files toggle | ✅ |
| Copy and move files and whole folder trees in both directions | ✅ |
| Progress, speed, time remaining, cancel, retry, persistent history | ✅ |
| Conflict handling: Skip / Replace / Keep Both (Finder‑style "Photo 2.jpg"), "apply to all" | ✅ |
| Drag and drop between panes, and from Finder onto the phone pane | ✅ |
| New folder, rename, delete (with confirmation), copy/paste within the phone | ✅ |
| Open / Quick Look phone files (fetched to a temporary read‑only copy) | ✅ |
| Phone and Mac free‑space display | ✅ |
| Wi‑Fi: pair with code, connect, mDNS discovery, remembered phones, auto‑reconnect | ✅ implemented, **not yet tested with a real phone** |
| Finder sidebar integration (File Provider) | ❌ not built, see [docs/ROADMAP.md](docs/ROADMAP.md) |
| MTP mode (no USB debugging) | ❌ not built, see [docs/ROADMAP.md](docs/ROADMAP.md) |

## Installing

1. Install Google's Platform Tools (gives you `adb`), once:
   ```bash
   brew install --cask android-platform-tools
   ```
   Or download *SDK Platform‑Tools for Mac* from developer.android.com. If you already have Android Studio, AndroBridge finds its copy automatically.
2. Open `AndroBridge-<version>.dmg` and drag **AndroBridge** to **Applications**.
3. The app is **unsigned and not notarized** (that needs a paid Apple Developer account). The first time, macOS will refuse to open it:
   - Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to “AndroBridge was blocked”, then confirm.
   - Or in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/AndroBridge.app
     ```
   A copy you build yourself on your own Mac isn't quarantined and opens directly.

## Set up your phone (once)

Steps below are for a Google Pixel; other Android phones are similar (the Developer options menu may sit under a different heading).

1. **Settings → About phone** → tap **Build number** 7 times (enter your PIN). “You are now a developer.”
2. **Settings → System → Developer options** → turn on **USB debugging**.
3. Plug the phone in with a USB‑C data cable. Unlock it. On **“Allow USB debugging?”** tick **Always allow from this computer** and tap **Allow**.
4. AndroBridge shows the phone as *Connected* and opens *Internal storage*.

If the phone shows *Waiting for authorization* and no prompt appears: unplug/replug, or **Developer options → Revoke USB debugging authorizations** and reconnect. If it shows *No USB permission*, quit Android File Transfer / OpenMTP / Android Studio (only one app can own the USB interface).

### Wi‑Fi (Android 11+)

Phone and Mac on the same network. On the phone: **Developer options → Wireless debugging** → on. In AndroBridge: sidebar → **Connect over Wi‑Fi…**
1. *Pair* (first time): on the phone tap **Pair device with pairing code**; enter the IP:port and 6‑digit code it shows.
2. *Connect*: enter the IP:port shown at the top of the Wireless debugging screen (different from the pairing port), or click a phone found by **Scan Network**.

Remembered phones reconnect at launch (the phone's port changes when Wireless debugging is toggled; AndroBridge looks it up via mDNS).

## Using it

- **Left pane** = Mac, **right pane** = phone. The pane with the blue line is active; toolbar and menu commands act on it.
- Copy: drag between panes, or select and press **⇧⌘→** (to phone) / **⇧⌘←** (to Mac). Add **⌥** to *move*.
- Files go into the folder currently open in the other pane.
- **Return** / double‑click opens; **Space** Quick Looks; **⌘⌫** deletes; **⇧⌘N** new folder; **⇧⌘R** rename; **⌘[ ⌘] ⌘↑** navigate; **⌘1 / ⌘2** list / icons; **⇧⌘.** hidden files; **⌘R** refresh; **⇧⌘K** Wi‑Fi.
- Settings (⌘,): SHA‑256 verification on/off (moves always verify), default conflict behaviour, custom adb path, Wi‑Fi auto‑reconnect.

### What Android lets you see

AndroBridge sees what `adb shell` can see: all of shared storage (`/sdcard` = Internal storage: DCIM, Pictures, Movies, Music, Download, Documents …) and SD cards. It can't see apps' private data, and newer Android versions restrict `Android/data` and `Android/obb`. Top‑level folders such as DCIM, Download or Android can't be deleted or replaced from AndroBridge, and nothing can be written outside shared storage.

## Building from source

Requires Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/arunmenon1807/androbridge.git && cd androbridge
swift test                      # unit tests, no phone needed
scripts/build-app.sh            # → dist/AndroBridge.app and dist/AndroBridge-0.1.0.dmg
```

Options: `--arch arm64` (Apple Silicon only, faster), `--bundle-adb` (copy your installed adb into the app so it works without Homebrew; personal use, see licensing below), `VERSION=1.2.3`, `SIGN_IDENTITY="Developer ID Application: …"` to sign with a real certificate.

Open in Xcode with `xed .` (Xcode opens `Package.swift` as a project; pick the *AndroBridge* scheme and Run). For quick iteration, `swift run AndroBridge`.

### Tests

| Suite | Needs a phone? | What it covers |
| --- | --- | --- |
| `AndroBridgeCoreTests` (19 tests) | No | adb output parsing (devices, listings, df, checksums, mDNS, errors), shell quoting (fed through a real `/bin/sh`), path safety rules, Finder‑style naming, local file manifests and SHA‑256, verification logic incl. NFC/NFD names |
| `DeviceIntegrationTests` (10 tests) | **Yes**, phone or emulator | Real adb: listing, storage, mkdir/rename/delete with Unicode, protected paths refused, 3 MB file round trip byte‑for‑byte, 180 MB download, nested folder round trip with SHA‑256, conflicts (keep both/skip/replace), move deletes source only after verify, cancelled upload leaves no partial files |

```bash
ANDROBRIDGE_DEVICE_TESTS=1 swift test --filter DeviceIntegrationTests
ANDROBRIDGE_DEVICE_TESTS=1 ANDROBRIDGE_DEVICE_SERIAL=<serial> swift test --filter DeviceIntegrationTests
```

They create and remove `/sdcard/Download/AndroBridgeTest-*` on the device. **Passing on an emulator is not proof the app works on a physical Pixel**; see [docs/PHONE-TEST-CHECKLIST.md](docs/PHONE-TEST-CHECKLIST.md) for the checks only a real phone can answer.

### CI

`.github/workflows/build.yml` runs the unit tests and builds the universal, unsigned `.app` + `.dmg` on a macOS runner; the DMG is uploaded as the `AndroBridge-dmg` artifact. Pushing a `v*` tag also creates a GitHub Release with the DMG attached.

## Licensing

AndroBridge is released under the [MIT License](LICENSE). Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md); security issues go through [SECURITY.md](SECURITY.md).

### adb

`adb` is part of Google's Android SDK Platform‑Tools. The downloadable binaries are covered by the Android SDK License Agreement, which restricts redistribution, so **the DMG built by CI does not include adb**; you install it yourself (step 1 above). `--bundle-adb` copies *your own* installed copy into *your own* build for convenience.

## Project layout

```
Sources/AndroBridgeCore/   device, transfer and file logic (no UI)
  ADB/                     ADBClient, AndroidDevice (DeviceConnection over adb), parser, locator
  Services/                FileTransferService, TransferQueueManager, DeviceDiscoveryService,
                           WirelessConnectionService, LocalFileService, SettingsManager
  Util/                    ProcessRunner (argv-only subprocesses), ShellQuoting
Sources/AndroBridge/       SwiftUI app (views + view models)
Tests/                     unit + device integration tests
scripts/build-app.sh       .app + .dmg packaging
docs/                      architecture, roadmap, real-phone test checklist
```

More: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Disclaimer

AndroBridge is an independent project and is not affiliated with, endorsed by or sponsored by Google. Android, Google Pixel and adb are trademarks or products of Google LLC; they are named here only to describe compatibility.
