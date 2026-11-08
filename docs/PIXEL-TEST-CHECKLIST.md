# Physical Pixel test checklist

Automated tests ran against an emulator. These need your real phone. Tick them off once.

## Run the device tests on the Pixel

```bash
PIXELBRIDGE_DEVICE_TESTS=1 swift test --filter DeviceIntegrationTests
```
(9 tests; they create and delete `/sdcard/Download/PixelBridgeTest-*`.)

## Manual checks in the app

- [ ] Plug in with USB debugging **off** → setup instructions show.
- [ ] Turn USB debugging on → “Waiting for authorization”; tap Allow → becomes Connected and opens Internal storage.
- [ ] DCIM/Camera lists your real photos with sizes and dates.
- [ ] Copy one photo to the Mac; open it.
- [ ] Copy a large video (1 GB+) to the Mac; progress, speed and time remaining update; SHA-256 verified at the end.
- [ ] Copy a folder with sub-folders from the Mac to the phone; it appears in Files / Google Photos.
- [ ] A file with spaces and non-English characters in its name copies both ways.
- [ ] Unplug the cable during a large transfer: no crash, the transfer fails with a clear message, no `.pixelbridge-…partial` left in the destination; replug and Retry works.
- [ ] Copy the same file twice: conflict dialog appears; Keep Both makes “name 2.ext”.
- [ ] Delete a file on the phone: confirmation dialog, then gone.
- [ ] Try to delete DCIM: refused.
- [ ] Wi‑Fi: pair with code, connect, browse, copy a file; toggle Wireless debugging off/on and use Reconnect.
- [ ] Quit and reopen the app with the phone plugged in: reconnects without prompts.
