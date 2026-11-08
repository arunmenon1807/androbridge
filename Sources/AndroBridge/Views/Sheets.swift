import AndroBridgeCore
import SwiftUI

// MARK: - Conflict

struct ConflictSheet: View {
    @Environment(AppModel.self) private var app
    let prompt: ConflictPrompt
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("“\(prompt.context.existingName)” already exists", systemImage: "doc.on.doc")
                .font(.headline)
            Text(prompt.context.request.direction == .toMac
                 ? "A \(prompt.context.existingIsDirectory ? "folder" : "file") with this name is already in “\((prompt.context.request.destinationDirectory as NSString).lastPathComponent)” on your Mac."
                 : "A \(prompt.context.existingIsDirectory ? "folder" : "file") with this name is already in “\(RemotePath.name(prompt.context.request.destinationDirectory))” on the phone.")
            Text(prompt.context.request.direction == .toMac
                 ? "Replace moves the existing item to the Trash after the new copy is verified."
                 : "Replace permanently deletes the existing item on the phone after the new copy is verified.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Apply to all remaining items", isOn: $applyToAll)
            HStack {
                Button("Skip") { app.answerConflict(.skip, applyToAll: applyToAll) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Replace", role: .destructive) { app.answerConflict(.replace, applyToAll: applyToAll) }
                Button("Keep Both") { app.answerConflict(.keepBoth, applyToAll: applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}

// MARK: - New folder / rename

struct NameSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: NameRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let problem = validation {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = request.initialName }
    }

    private var isRename: Bool {
        if case .rename = request.kind { return true }
        return false
    }

    private var title: String {
        let place = request.side == .mac ? "on your Mac" : "on the phone"
        return isRename ? "Rename “\(request.initialName)”" : "New folder \(place)"
    }

    private var validation: String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Enter a name." }
        if request.side == .phone && !RemotePath.isValidName(n) { return "Names on Android can’t contain / \\ : * ? \" < > |" }
        if n.contains("/") { return "Names can’t contain “/”." }
        return nil
    }

    private func commit() {
        guard validation == nil else { return }
        app.commitName(request, name: name)
        dismiss()
    }
}

// MARK: - Wireless

struct WirelessSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var connectAddress = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var discovered: [ADBOutputParser.MDNSService] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect over Wi-Fi", systemImage: "wifi").font(.title3.bold())
            Text("Needs Android 11 or later, with the phone and Mac on the same Wi-Fi network. On the phone open **Settings → System → Developer options → Wireless debugging** and turn it on.")
                .font(.callout)

            GroupBox("1 · Pair (first time only)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tap **Pair device with pairing code** on the phone and enter the IP address & port and 6-digit code it shows.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("192.168.1.20:37011", text: $pairAddress).textFieldStyle(.roundedBorder)
                        TextField("Code", text: $pairCode).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button("Pair") { Task { await pair() } }.disabled(busy || pairAddress.isEmpty || pairCode.isEmpty)
                    }
                }
                .padding(4)
            }

            GroupBox("2 · Connect") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use the **IP address & port** shown at the top of the Wireless debugging screen (it differs from the pairing port).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("192.168.1.20:41235", text: $connectAddress).textFieldStyle(.roundedBorder)
                        Button("Connect") { Task { await connect(connectAddress) } }.disabled(busy || connectAddress.isEmpty)
                    }
                    if !discovered.isEmpty {
                        Text("Found on this network:").font(.caption)
                        ForEach(discovered, id: \.self) { svc in
                            HStack {
                                Image(systemName: svc.isPairing ? "link" : "smartphone")
                                Text("\(svc.address)").font(.system(.caption, design: .monospaced))
                                Text(svc.isPairing ? "pairing" : "ready").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(svc.isPairing ? "Use for pairing" : "Connect") {
                                    if svc.isPairing { pairAddress = svc.address } else { Task { await connect(svc.address) } }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(4)
            }

            if !app.settings.rememberedWireless.isEmpty {
                GroupBox("Remembered phones") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.settings.rememberedWireless) { d in
                            HStack {
                                Text(d.name)
                                Text("\(d.host):\(String(d.port))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Button("Connect") { Task { await connect("\(d.host):\(d.port)") } }.controlSize(.small)
                                Button { app.settings.forget(d) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Forget")
                            }
                        }
                        Button("Reconnect All") { Task { busy = true; await app.reconnectWireless(silent: false); busy = false } }
                            .controlSize(.small)
                    }
                    .padding(4)
                }
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(isError ? .red : .green)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Scan Network") { Task { await scan() } }.disabled(busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await scan() }
    }

    private var service: WirelessConnectionService? {
        app.discovery.client.map { WirelessConnectionService(client: $0) }
    }

    private func scan() async {
        guard let service else { return }
        discovered = await service.discover()
    }

    private func pair() async {
        guard let service, let (host, port) = WirelessConnectionService.parseAddress(pairAddress) else {
            show("Enter the address as IP:port, e.g. 192.168.1.20:37011", error: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            _ = try await service.pair(host: host, port: port, code: pairCode)
            show("Paired. Now connect using the IP address & port from the Wireless debugging screen.", error: false)
            pairCode = ""
            if connectAddress.isEmpty { connectAddress = host + ":" }
            await scan()
            if let svc = discovered.first(where: { $0.isConnect && $0.address.hasPrefix(host + ":") }) {
                await connect(svc.address)
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func connect(_ address: String) async {
        guard let service, let (host, port) = WirelessConnectionService.parseAddress(address) else {
            show("Enter the address as IP:port, e.g. 192.168.1.20:41235", error: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await service.connect(host: host, port: port)
            await app.discovery.refresh()
            let serial = "\(host):\(port)"
            let name = app.discovery.devices.first { $0.serial == serial }?.displayName ?? host
            app.settings.remember(RememberedWirelessDevice(name: name, host: host, port: port))
            app.selectDevice(serial)
            show("Connected to \(name).", error: false)
        } catch {
            show(error.localizedDescription + " If you haven’t paired this Mac yet, do step 1 first.", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Transfers") {
                Toggle("Verify every copy with SHA-256 checksums", isOn: $settings.verifyChecksums)
                Text("Sizes are always compared. Moves always use SHA-256 before removing the original.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("When an item already exists", selection: $settings.conflictPolicy) {
                    ForEach(DefaultConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            }
            Section("Wi-Fi") {
                Toggle("Reconnect to remembered phones at launch", isOn: $settings.autoReconnectWireless)
            }
            Section("adb") {
                TextField("Custom adb path (optional)", text: $settings.adbPathOverride)
                HStack {
                    Text(app.discovery.client?.adbURL.path ?? "adb not found")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Apply") { app.restartADB() }
                }
                if let v = app.discovery.adbVersion {
                    Text(v).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("AndroBridge works entirely on this Mac. It has no accounts, no analytics and makes no network connections except to phones you connect with adb.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding(.vertical, 8)
    }
}
