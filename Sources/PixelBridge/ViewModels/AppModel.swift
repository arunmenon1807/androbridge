import AppKit
import Foundation
import Observation
import PixelBridgeCore
import UniformTypeIdentifiers

/// A pending "item already exists" question shown as a sheet.
struct ConflictPrompt: Identifiable {
    let id = UUID()
    let context: ConflictContext
    let continuation: CheckedContinuation<ConflictResolution, Never>
}

/// What "Copy" put on PixelBridge's internal clipboard.
struct PaneClipboard {
    let side: PaneSide
    let paths: [String]
    let serial: String?
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let side: PaneSide
    let items: [FileItem]
}

struct NameRequest: Identifiable {
    enum Kind { case newFolder, rename(FileItem) }
    let id = UUID()
    let side: PaneSide
    let kind: Kind
    var initialName: String
}

/// App-wide state: devices, the two panes, transfers and dialogs.
@MainActor
@Observable
final class AppModel {
    let settings = SettingsManager()
    let discovery = DeviceDiscoveryService()
    let queue = TransferQueueManager()

    let macPane: PaneModel
    let phonePane = PaneModel(side: .phone, path: SafetyPolicy.defaultRoot)

    var selectedSerial: String?
    var deviceDetails: DeviceDetails?
    var activeSide: PaneSide = .mac

    var conflictPrompt: ConflictPrompt?
    private var conflictApplyToAll: ConflictResolution?
    var deleteRequest: DeleteRequest?
    var nameRequest: NameRequest?
    var alertMessage: String?
    var banner: String?
    var showWirelessSheet = false
    var showTransferPanel = true
    var previewURL: URL?
    var isPreparingPreview = false
    var clipboard: PaneClipboard?

    init() {
        let start = SettingsManager().lastLocalPath
        let path = FileManager.default.fileExists(atPath: start)
            ? start
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        macPane = PaneModel(side: .mac, path: path)
        wire()
    }

    // MARK: Setup

    private func wire() {
        macPane.lister = { path in
            try LocalFileService.list(URL(fileURLWithPath: path, isDirectory: true))
        }
        macPane.storageReader = { path in
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
                  let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
            return StorageInfo(totalBytes: Int64(total), usedBytes: Int64(total) - free, availableBytes: free)
        }
        macPane.showHidden = { [weak self] in self?.settings.showHiddenFiles ?? false }
        phonePane.showHidden = { [weak self] in self?.settings.showHiddenFiles ?? false }
        phonePane.lister = { [weak self] path in
            guard let self, let device = self.currentConnection else { throw DeviceError.deviceDisconnected }
            return try await device.list(path)
        }
        phonePane.storageReader = { [weak self] path in
            guard let device = self?.currentConnection else { return nil }
            return try? await device.storageInfo(path)
        }

        queue.deviceProvider = { [weak self] serial in self?.discovery.connection(for: serial) }
        queue.optionsProvider = { [weak self] in TransferOptions(verifyChecksums: self?.settings.verifyChecksums ?? true) }
        queue.conflictHandler = { [weak self] context in
            guard let self else { return .skip }
            return await self.resolveConflict(context)
        }
        queue.onItemFinished = { [weak self] item in
            guard let self else { return }
            // Refresh whichever pane shows the destination or the (moved) source.
            switch item.request.direction {
            case .toMac:
                if self.macPane.path == item.request.destinationDirectory { self.macPane.reload() }
                if item.request.operation == .move { self.phonePane.reload() }
            case .toDevice:
                if self.phonePane.path == item.request.destinationDirectory { self.phonePane.reload() }
                if item.request.operation == .move { self.macPane.reload() }
            }
            if !self.queue.hasActiveTransfers { self.conflictApplyToAll = nil }
        }

        discovery.onChange = { [weak self] old, new in
            self?.devicesChanged(old: old, new: new)
        }
    }

    func start() {
        discovery.start(adbOverride: settings.adbPathOverride)
        macPane.reload()
        if settings.autoReconnectWireless, !settings.rememberedWireless.isEmpty {
            Task { await reconnectWireless(silent: true) }
        }
    }

    func restartADB() {
        discovery.start(adbOverride: settings.adbPathOverride)
    }

    // MARK: Devices

    var selectedDevice: ADBDevice? {
        discovery.devices.first { $0.serial == selectedSerial }
    }

    var currentConnection: AndroidDevice? {
        guard let selectedSerial else { return nil }
        return discovery.connection(for: selectedSerial)
    }

    var isPhoneReady: Bool { selectedDevice?.state.isReady == true }

    private func devicesChanged(old: [ADBDevice], new: [ADBDevice]) {
        let oldReady = Set(old.filter { $0.state.isReady }.map(\.serial))
        let newReady = Set(new.filter { $0.state.isReady }.map(\.serial))

        // Selected device went away or lost authorization.
        if let sel = selectedSerial, oldReady.contains(sel), !newReady.contains(sel) {
            let name = old.first { $0.serial == sel }?.displayName ?? "The phone"
            banner = "\(name) disconnected. Reconnect it to continue; files already transferred are safe."
            phonePane.clear(error: nil)
            deviceDetails = nil
            if new.first(where: { $0.serial == sel }) == nil { selectedSerial = nil }
        }

        // Pick a device automatically: keep the current one if present, else the first ready one,
        // else the first one shown at all (so its setup instructions appear).
        if selectedSerial == nil || !new.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = new.first(where: { $0.state.isReady })?.serial ?? new.first?.serial
        }

        if let sel = selectedSerial, newReady.contains(sel), !oldReady.contains(sel) {
            banner = nil
            deviceBecameReady(sel)
        }
    }

    func selectDevice(_ serial: String) {
        guard serial != selectedSerial else { return }
        selectedSerial = serial
        phonePane.clear(error: nil)
        deviceDetails = nil
        if discovery.devices.first(where: { $0.serial == serial })?.state.isReady == true {
            deviceBecameReady(serial)
        }
    }

    private func deviceBecameReady(_ serial: String) {
        phonePane.reset(to: SafetyPolicy.defaultRoot)
        Task {
            if let c = discovery.connection(for: serial) {
                deviceDetails = try? await c.details()
            }
        }
    }

    // MARK: Wireless

    func reconnectWireless(silent: Bool) async {
        guard let client = discovery.client else { return }
        let svc = WirelessConnectionService(client: client)
        let connected = await svc.reconnect(settings.rememberedWireless)
        for d in connected { settings.remember(d) }
        await discovery.refresh()
        if !silent {
            banner = connected.isEmpty
                ? "Couldn’t reach any remembered phone. Make sure Wireless debugging is on and you’re on the same Wi-Fi."
                : "Reconnected \(connected.map(\.name).joined(separator: ", "))."
        }
    }

    // MARK: Transfers

    /// Copy (or move) items from one pane into the other pane's current folder.
    func transfer(from side: PaneSide, items: [FileItem], operation: TransferOperation = .copy) {
        guard let device = selectedDevice, device.state.isReady else {
            alertMessage = "Connect and authorize your phone first."
            return
        }
        guard !items.isEmpty else { return }
        let requests: [TransferRequest] = items.map { item in
            TransferRequest(
                direction: side == .mac ? .toDevice : .toMac,
                operation: operation,
                sourcePath: item.path,
                destinationDirectory: side == .mac ? phonePane.path : macPane.path,
                deviceSerial: device.serial,
                deviceName: device.displayName
            )
        }
        enqueue(requests)
    }

    /// Upload arbitrary local URLs (e.g. dropped from Finder) into the phone pane's folder.
    func upload(urls: [URL], to remoteDir: String? = nil) {
        guard let device = selectedDevice, device.state.isReady else {
            alertMessage = "Connect and authorize your phone first."
            return
        }
        let requests = urls.map {
            TransferRequest(direction: .toDevice, operation: .copy, sourcePath: $0.path,
                            destinationDirectory: remoteDir ?? phonePane.path,
                            deviceSerial: device.serial, deviceName: device.displayName)
        }
        enqueue(requests)
    }

    func download(remotePaths: [String], to localDir: String? = nil) {
        guard let device = selectedDevice, device.state.isReady else {
            alertMessage = "Connect and authorize your phone first."
            return
        }
        let requests = remotePaths.map {
            TransferRequest(direction: .toMac, operation: .copy, sourcePath: $0,
                            destinationDirectory: localDir ?? macPane.path,
                            deviceSerial: device.serial, deviceName: device.displayName)
        }
        enqueue(requests)
    }

    private func enqueue(_ requests: [TransferRequest]) {
        guard !requests.isEmpty else { return }
        if requests.first?.direction == .toDevice, !SafetyPolicy.isWritableLocation(requests[0].destinationDirectory) {
            alertMessage = "Android doesn’t allow copying into “\(requests[0].destinationDirectory)”. Choose a folder in Internal storage."
            return
        }
        showTransferPanel = true
        queue.enqueue(requests)
    }

    private func resolveConflict(_ context: ConflictContext) async -> ConflictResolution {
        switch settings.conflictPolicy {
        case .keepBoth: return .keepBoth
        case .skip: return .skip
        case .ask: break
        }
        if let all = conflictApplyToAll { return all }
        return await withCheckedContinuation { cont in
            conflictPrompt = ConflictPrompt(context: context, continuation: cont)
        }
    }

    func answerConflict(_ resolution: ConflictResolution, applyToAll: Bool) {
        guard let prompt = conflictPrompt else { return }
        if applyToAll { conflictApplyToAll = resolution }
        conflictPrompt = nil
        prompt.continuation.resume(returning: resolution)
    }

    // MARK: File management

    func pane(_ side: PaneSide) -> PaneModel { side == .mac ? macPane : phonePane }

    var activePane: PaneModel { pane(activeSide) }

    func requestNewFolder(on side: PaneSide) {
        if side == .phone && !isPhoneReady { return }
        if side == .phone && !SafetyPolicy.isWritableLocation(phonePane.path) {
            alertMessage = "You can’t create folders here. Choose a folder in Internal storage."
            return
        }
        nameRequest = NameRequest(side: side, kind: .newFolder, initialName: "New Folder")
    }

    func requestRename(on side: PaneSide) {
        let sel = pane(side).selectedItems
        guard sel.count == 1, let item = sel.first else { return }
        nameRequest = NameRequest(side: side, kind: .rename(item), initialName: item.name)
    }

    func commitName(_ request: NameRequest, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pane(request.side)
        Task {
            do {
                switch (request.side, request.kind) {
                case (.mac, .newFolder):
                    try LocalFileService.makeDirectory(URL(fileURLWithPath: p.childPath(name)))
                case (.mac, .rename(let item)):
                    guard name != item.name else { return }
                    _ = try LocalFileService.rename(URL(fileURLWithPath: item.path), to: name)
                case (.phone, .newFolder):
                    guard let c = currentConnection else { throw DeviceError.deviceDisconnected }
                    guard RemotePath.isValidName(name) else { throw DeviceError.invalidName(name) }
                    try await c.makeDirectory(p.childPath(name))
                case (.phone, .rename(let item)):
                    guard name != item.name else { return }
                    guard let c = currentConnection else { throw DeviceError.deviceDisconnected }
                    try await c.rename(item.path, to: RemotePath.join(RemotePath.parent(item.path), name))
                }
                p.reload()
                p.selection = [p.childPath(name)]
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func requestDelete(on side: PaneSide) {
        let items = pane(side).selectedItems
        guard !items.isEmpty else { return }
        if side == .phone, let protected = items.first(where: { SafetyPolicy.isProtected($0.path) }) {
            alertMessage = DeviceError.protectedPath(protected.path).localizedDescription
            return
        }
        deleteRequest = DeleteRequest(side: side, items: items)
    }

    func confirmDelete(_ request: DeleteRequest) {
        let p = pane(request.side)
        Task {
            var failures: [String] = []
            for item in request.items {
                do {
                    switch request.side {
                    case .mac: try LocalFileService.moveToTrash(URL(fileURLWithPath: item.path))
                    case .phone:
                        guard let c = currentConnection else { throw DeviceError.deviceDisconnected }
                        try await c.delete(item.path)
                    }
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            p.reload()
            if !failures.isEmpty { alertMessage = failures.joined(separator: "\n") }
        }
    }

    // MARK: Clipboard (copy / paste within and across panes)

    func copySelection(on side: PaneSide) {
        let paths = pane(side).selectedItems.map(\.path)
        guard !paths.isEmpty else { return }
        clipboard = PaneClipboard(side: side, paths: paths, serial: side == .phone ? selectedSerial : nil)
        if side == .mac {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        }
    }

    func canPaste(on side: PaneSide) -> Bool {
        guard let clipboard else { return false }
        if side == .phone || clipboard.side == .phone { return isPhoneReady }
        return true
    }

    /// Paste into `side`'s current folder. Across panes this is a transfer; within the
    /// phone it's an on-device copy; within the Mac it's a Finder-style copy.
    func paste(on side: PaneSide) {
        guard let clip = clipboard else { return }
        let dest = pane(side)
        switch (clip.side, side) {
        case (.mac, .phone):
            upload(urls: clip.paths.map { URL(fileURLWithPath: $0) })
        case (.phone, .mac):
            download(remotePaths: clip.paths)
        case (.phone, .phone):
            guard let c = currentConnection, clip.serial == selectedSerial else {
                alertMessage = "Copied items were on a different device."
                return
            }
            Task {
                do {
                    let existing = Set(dest.items.map(\.name))
                    for src in clip.paths {
                        let name = ConflictNaming.uniqueName(for: RemotePath.name(src), isDirectory: false) { existing.contains($0) }
                        try await c.copy(src, to: RemotePath.join(dest.path, name))
                    }
                } catch {
                    alertMessage = error.localizedDescription
                }
                dest.reload()
            }
        case (.mac, .mac):
            do {
                for src in clip.paths {
                    let srcURL = URL(fileURLWithPath: src)
                    let name = ConflictNaming.uniqueName(for: srcURL.lastPathComponent, isDirectory: LocalFileService.isDirectory(srcURL)) {
                        LocalFileService.exists(URL(fileURLWithPath: dest.childPath($0)))
                    }
                    try FileManager.default.copyItem(at: srcURL, to: URL(fileURLWithPath: dest.childPath(name)))
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            dest.reload()
        }
    }

    /// Move selected items on the phone into another folder on the phone.
    func moveOnPhone(paths: [String], into folder: String) {
        guard let c = currentConnection else { return }
        Task {
            do {
                for src in paths where RemotePath.parent(src) != folder && src != folder {
                    try await c.rename(src, to: RemotePath.join(folder, RemotePath.name(src)))
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            phonePane.reload()
        }
    }

    // MARK: Open / preview

    func open(_ item: FileItem, on side: PaneSide) {
        if pane(side).open(item) { return }
        switch side {
        case .mac:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        case .phone:
            Task {
                if let url = await fetchTemporaryCopy(of: item) { NSWorkspace.shared.open(url) }
            }
        }
    }

    func quickLook(on side: PaneSide) {
        guard let item = pane(side).selectedItems.first, !item.isDirectory else { return }
        switch side {
        case .mac:
            previewURL = URL(fileURLWithPath: item.path)
        case .phone:
            Task {
                if let url = await fetchTemporaryCopy(of: item) { previewURL = url }
            }
        }
    }

    /// Pulls a phone file into ~/Library/Caches/PixelBridge/Previews for viewing.
    /// The copy is read-only and cleaned up on next launch.
    private func fetchTemporaryCopy(of item: FileItem) async -> URL? {
        guard let c = currentConnection else { return nil }
        if item.size > 2_000_000_000 {
            alertMessage = "“\(item.name)” is large. Copy it to your Mac to open it."
            return nil
        }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        let dir = Self.previewCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(item.name)
            try await c.pull(item.path, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
            return dest
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    static let previewCache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PixelBridge/Previews", isDirectory: true)

    static func clearPreviewCache() {
        try? FileManager.default.removeItem(at: previewCache)
    }
}
