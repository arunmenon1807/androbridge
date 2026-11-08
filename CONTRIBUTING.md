# Contributing to AndroBridge

Thanks for your interest! Bug reports, phone compatibility reports and pull requests are all welcome.

## Reporting a bug

Open an issue with the **Bug report** template. The most useful details are your macOS version, Mac (Apple Silicon or Intel), phone model, Android version, whether you're on USB or Wi‑Fi, and what the transfer panel or error message said.

## Development setup

You need Xcode 16 or later and Android Platform Tools (`brew install --cask android-platform-tools`).

```bash
swift build                 # build
swift run AndroBridge       # run the app without packaging
swift test                  # unit tests (no phone needed)
scripts/build-app.sh --arch arm64   # package dist/AndroBridge.app + .dmg
```

Open the package in Xcode with `xed .`.

### Device tests

`DeviceIntegrationTests` run real transfers against a connected phone or emulator and are skipped by default:

```bash
ANDROBRIDGE_DEVICE_TESTS=1 swift test --filter DeviceIntegrationTests
```

They only touch `/sdcard/Download/AndroBridgeTest-*` and clean up afterwards. An Android Studio emulator is fine for most changes; mention in your PR whether you also tested on a physical phone.

## Code layout

- `Sources/AndroBridgeCore`: everything that talks to adb or moves files. No UI. New logic here should come with tests.
- `Sources/AndroBridge`: the SwiftUI app.
- See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how transfers are staged and verified.

## Ground rules for changes

- **Never** build a shell command string on the Mac; pass arguments to `ProcessRunner` as an array.
- Every path sent to `adb shell` must go through `ShellQuoting.quote`.
- Don't weaken the transfer safety model (stage → verify → finalize; sources removed only after verification; no silent overwrites).
- No telemetry, analytics, accounts or network calls other than adb.

## Pull requests

1. Fork, then branch from `main`.
2. Keep each PR focused; add or update tests.
3. Make sure `swift test` passes and the app builds (`swift build`).
4. Describe what you changed and how you tested it.

By contributing you agree your work is released under the [MIT License](LICENSE).
