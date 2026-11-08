import PixelBridgeCore
import SwiftUI

/// Shown in the phone pane until a device is connected and authorized.
struct DeviceSetupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                steps
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var header: some View {
        if app.discovery.adbError != nil {
            Label("Android Platform Tools needed", systemImage: "wrench.and.screwdriver")
                .font(.title2.bold())
            Text("PixelBridge uses Google’s free adb tool to talk to your phone. Install it once:")
            Text("brew install --cask android-platform-tools")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Or download “SDK Platform-Tools for Mac” from developer.android.com, then point PixelBridge at the adb file in Settings.")
                .foregroundStyle(.secondary)
            Button("Try Again") { app.restartADB() }
        } else if let device = app.selectedDevice {
            switch device.state {
            case .unauthorized:
                Label("Allow this Mac on your phone", systemImage: "lock.shield")
                    .font(.title2.bold())
                Text("Unlock **\(device.displayName)**. A prompt “Allow USB debugging?” is waiting. Tick **Always allow from this computer**, then tap **Allow**.")
                Text("No prompt? Unplug and replug the cable, or on the phone open Developer options → **Revoke USB debugging authorizations**, then reconnect.")
                    .foregroundStyle(.secondary)
            case .offline:
                Label("Phone not responding", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.title2.bold())
                Text("Unlock the phone and wait a moment. If it stays offline, unplug and reconnect the cable.")
                Button("Restart adb") { app.restartADB() }
            case .noPermissions:
                Label("Phone is busy", systemImage: "exclamationmark.triangle")
                    .font(.title2.bold())
                Text("Another app is using the phone’s USB connection (for example Android File Transfer, OpenMTP or Android Studio). Quit it and reconnect.")
            default:
                Label("Phone is in \(device.state.displayName)", systemImage: "exclamationmark.triangle")
                    .font(.title2.bold())
                Text("Restart the phone normally to browse its files.")
            }
        } else {
            Label("Connect your Android phone", systemImage: "cable.connector")
                .font(.title2.bold())
            Text("Plug your Pixel into this Mac with a USB-C cable. It appears here automatically.")
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for devices…").foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("First time? Turn on USB debugging (once):").font(.headline)
            step(1, "On the phone open **Settings → About phone** and tap **Build number** 7 times. Enter your PIN if asked.")
            step(2, "Go to **Settings → System → Developer options** and turn on **USB debugging**.")
            step(3, "Connect the cable. When the phone asks “Allow USB debugging?”, tick **Always allow from this computer** and tap **Allow**.")
            step(4, "If the phone shows a USB notification, “File transfer” or “No data transfer” both work for PixelBridge.")
            Text("Prefer Wi-Fi? Use **Connect over Wi-Fi…** in the sidebar (Android 11 or later).")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }
}
