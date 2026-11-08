# Architecture

## Why adb

macOS has no built-in MTP support, and Apple's File Provider and USB APIs don't speak Android. The most reliable path to a Pixel is Google's own `adb`: it ships for macOS, is maintained alongside Android, supports USB and authenticated Wi‑Fi, and its `push`/`pull` sync protocol is fast (100–200+ MB/s over USB 3) and handles large files. The cost is that the user must enable USB debugging once.

## Layers

```
SwiftUI views ── AppModel / PaneModel (view models, @Observable)
                     │
PixelBridgeCore ─────┼───────────────────────────────────────────────
  DeviceDiscoveryService   polls `adb devices -l` every 1.5 s
  TransferQueueManager     serial queue, progress/speed/ETA, history (JSON)
  FileTransferService      one verified transfer (staging → verify → finalize)
  WirelessConnectionService pair / connect / mDNS / reconnect
  LocalFileService         Mac-side listing, manifests, SHA-256, Trash
  SettingsManager          UserDefaults
  DeviceConnection (protocol) ◄── AndroidDevice (adb)   [future: MTPDevice]
  ADBClient → ProcessRunner (argv only, never a local shell)
```

The design document's `ADBConnectionService` is `ADBClient`; `FileBrowserService` is split between `DeviceConnection.list` (phone) and `LocalFileService` (Mac); `StorageInfoService` is `DeviceConnection.storageInfo`; `FinderIntegrationService` and `MTPConnectionService` don't exist yet (see ROADMAP).

## Command safety

- Every adb call is `Process` with an argument array. Paths never pass through a Mac shell.
- Commands that run on the phone go through `adb shell`, which *does* use the phone's `sh`. Every path is single‑quoted by `ShellQuoting.quote` (tested by feeding hostile strings through a real `/bin/sh`).
- `SafetyPolicy` refuses writes outside shared storage and refuses deleting/replacing storage roots, the standard top-level folders (DCIM, Download, …) and `Android/{data,obb}`.
- Rename uses an existence check plus `mv -n`; new folders use `mkdir` without `-p`. Nothing is overwritten implicitly.

## Transfer pipeline

1. **Prepare**: stat the source and build a manifest (relative path → size) of every regular file.
2. **Conflict**: if the destination name exists, ask (Skip / Replace / Keep Both) unless Settings says otherwise.
3. **Space check** on the destination volume.
4. **Copy** to `.pixelbridge-<uuid>.partial` beside the destination with `adb pull -a` / `adb push`. Progress comes from watching that item grow (local stat every 0.4 s; remote stat every 1 s).
5. **Verify**: file list and sizes must match; with checksums on (default, and always for moves) SHA‑256 is computed on both sides (`sha256sum` on the phone, CryptoKit streaming on the Mac).
6. **Finalize**: Replace moves the old Mac item to the Trash / deletes the old phone item, then renames the staging item into place.
7. **Move**: only now is the source removed (Mac sources to the Trash).

Cancel or failure at any step deletes the staging item; the source is untouched.

## Device lifecycle

`DeviceDiscoveryService` diff-checks `adb devices -l`. When the selected phone disappears or loses authorization, the phone pane switches to setup guidance and a banner explains what happened; running transfers fail with a clear message and can be retried. Polling restarts the adb server if it was killed, so recovery is automatic.

## Not sandboxed

The app runs `adb` as a subprocess and browses arbitrary folders, which the App Sandbox doesn't allow without heavy entitlements. It's a non-sandboxed, ad-hoc-signed app; macOS still asks the user before it reads Desktop/Documents/Downloads (TCC).
