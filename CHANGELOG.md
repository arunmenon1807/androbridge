# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Docs: USB and Wi-Fi verified on a physical Google Pixel.

### Fixed
- Wi-Fi pairing: clear explanations for adb pairing errors (wrong port, wrong code, unreachable) and a warning when the pairing and connect addresses are the same.
- The release `.sha256` file now names the DMG without a `dist/` prefix, so `shasum -a 256 -c` works after download.

## [0.1.0] - 2026-11-08

First public release.

### Added
- Automatic detection of Android phones over USB via adb, with guidance for unauthorized, offline and busy states, and automatic recovery after disconnects.
- Two-pane Mac ⟷ phone browser: breadcrumbs, back/forward/up, list and icon views, sorting, search, multi-select, hidden-file toggle.
- Verified transfers in both directions for files and nested folders: staged to a hidden temporary item, checked by size and SHA-256, then renamed into place. Copy and move, progress, speed, ETA, cancel, retry and persistent history.
- Conflict handling (Skip / Replace / Keep Both) with "apply to all".
- Drag and drop between panes and from Finder; copy/paste; new folder, rename and delete with confirmation; protected top-level phone folders.
- Quick Look and open for phone files via temporary read-only copies.
- Wi-Fi via adb Wireless debugging: pairing code, connect, mDNS discovery, remembered phones and reconnect at launch.
- Remembers the last Mac folder.
- Universal (Apple Silicon + Intel) unsigned app and DMG, built by GitHub Actions.

[0.1.0]: https://github.com/arunmenon1807/androbridge/releases/tag/v0.1.0
