import AndroBridgeCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    private var macFavourites: [(String, String, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Home", "house", home.path),
            ("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop").path),
            ("Documents", "doc", home.appendingPathComponent("Documents").path),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads").path),
            ("Pictures", "photo", home.appendingPathComponent("Pictures").path),
            ("Movies", "film", home.appendingPathComponent("Movies").path),
            ("Music", "music.note", home.appendingPathComponent("Music").path),
        ]
    }

    private let phoneLocations: [(String, String, String)] = [
        ("Internal storage", "internaldrive", "/sdcard"),
        ("Camera (DCIM)", "camera", "/sdcard/DCIM"),
        ("Pictures", "photo", "/sdcard/Pictures"),
        ("Movies", "film", "/sdcard/Movies"),
        ("Music", "music.note", "/sdcard/Music"),
        ("Download", "arrow.down.circle", "/sdcard/Download"),
        ("Documents", "doc", "/sdcard/Documents"),
    ]

    var body: some View {
        List {
            Section("Devices") {
                if let error = app.discovery.adbError {
                    Label {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else if app.discovery.devices.isEmpty {
                    Label("No phone connected", systemImage: "cable.connector.slash")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.discovery.devices) { device in
                    DeviceRow(device: device, isSelected: device.serial == app.selectedSerial)
                        .contentShape(Rectangle())
                        .onTapGesture { app.selectDevice(device.serial) }
                        .contextMenu {
                            if device.connectionKind == .wireless {
                                Button("Disconnect") {
                                    Task {
                                        if let c = app.discovery.client { try? await c.disconnect(serial: device.serial) }
                                        await app.discovery.refresh()
                                    }
                                }
                            }
                            Button("Copy Serial Number") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(device.serial, forType: .string)
                            }
                        }
                }
                Button {
                    app.showWirelessSheet = true
                } label: {
                    Label("Connect over Wi-Fi…", systemImage: "wifi")
                }
                .buttonStyle(.borderless)
                .disabled(app.discovery.client == nil)
            }

            if app.isPhoneReady {
                Section(app.selectedDevice?.displayName ?? "Phone") {
                    ForEach(phoneLocations, id: \.2) { loc in
                        Button {
                            app.activeSide = .phone
                            app.phonePane.navigate(to: loc.2)
                        } label: {
                            Label(loc.0, systemImage: loc.1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("This Mac") {
                ForEach(macFavourites, id: \.2) { fav in
                    Button {
                        app.activeSide = .mac
                        app.macPane.navigate(to: fav.2)
                    } label: {
                        Label(fav.0, systemImage: fav.1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DeviceRow: View {
    let device: ADBDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.connectionKind == .wireless ? "wifi" : (device.connectionKind == .emulator ? "desktopcomputer" : "smartphone"))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        let kind: String
        switch device.connectionKind {
        case .usb: kind = "USB"
        case .wireless: kind = "Wi-Fi"
        case .emulator: kind = "Emulator"
        }
        return "\(device.state.displayName) · \(kind)"
    }

    private var color: Color {
        switch device.state {
        case .device: return .green
        case .unauthorized, .offline: return .orange
        default: return .red
        }
    }
}
