# Roadmap and feasibility notes

## Phase status

| Phase | Status |
| --- | --- |
| 1 USB MVP | Done. Automated end-to-end tests on an Android 16 emulator over real adb; verified by the maintainer on a physical Google Pixel over USB ([checklist](PHONE-TEST-CHECKLIST.md)). |
| 2 Improved experience | Done: dual pane, drag & drop, Quick Look, search/sort, multi-select, queue, retry, history, conflict dialog. |
| 3 Wireless | Done (pair, connect, mDNS, remember, reconnect). Verified on a physical Google Pixel. |
| 4 Finder + MTP | Not started. Notes below. |

## Known gaps

- Dragging phone files **out to Finder** isn't supported (needs `NSFilePromiseProvider`); drag them to the Mac pane instead.
- Drag-and-drop onto a specific sub-folder row isn't supported; drops go to the folder open in that pane.
- Transfers run one at a time.
- Very large folders (tens of thousands of files) list fine but SHA-256 verification takes a while on the phone; turn checksums off in Settings for copies if speed matters (moves always verify).
- Photos pushed to the phone show up in Google Photos after Android's media scanner sees them (usually immediate on Android 11+).

## Finder integration (File Provider) — feasibility

Doable with public APIs (`NSFileProviderReplicatedExtension`, macOS 11+), but it needs:
- an app extension target (`.appex`) inside the app, which SwiftPM can't build — requires an Xcode project;
- App Group + sandbox entitlements for the extension, which in practice need a signing team (a free Apple ID works for local builds, but the extension is only loaded when properly signed);
- the extension itself can't spawn `adb` from its sandbox, so it would talk to the main app (or a small helper) over XPC, which does the adb work;
- enumeration, change tracking (sync anchors) and materialization of files on demand, plus cache invalidation on disconnect.

Estimate: a solid week of work plus signing setup. Recommended as its own milestone once the USB app has been used for a while on the real Pixel.

## MTP mode — feasibility

macOS has no MTP stack. Options:
- **libmtp + libusb** (LGPL-2.1): the proven route (OpenMTP, Android File Transfer alternatives use it). Would be vendored as a dynamic library to respect the LGPL, wrapped behind `DeviceConnection` as `MTPDevice`.
- Writing MTP over IOKit/libusb directly: more control, much more work.

Caveats: MTP is slow for many small files, can't do atomic rename-into-place (verification would compare after writing), and only one process may hold the USB interface, so it can't run alongside adb on the same phone. Estimate: 1–2 weeks.
