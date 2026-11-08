import AppKit
import PixelBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// One side of the dual-pane browser (Mac or phone).
struct PaneView: View {
    @Environment(AppModel.self) private var app
    @Bindable var pane: PaneModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane)
            Divider()
            ZStack {
                content
                if pane.isLoading && pane.items.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PaneFooter(pane: pane)
        }
        .background(app.activeSide == pane.side ? Color.accentColor.opacity(0.04) : Color.clear)
        .overlay(alignment: .top) {
            if app.activeSide == pane.side {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { app.activeSide = pane.side })
        .modifier(DropTargetModifier(pane: pane))
    }

    @ViewBuilder
    private var content: some View {
        if pane.side == .phone && !app.isPhoneReady {
            DeviceSetupView()
        } else if let error = pane.error {
            ContentUnavailableView {
                Label("Can’t open this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                HStack {
                    Button("Try Again") { pane.reload() }
                    if pane.canGoBack { Button("Go Back") { pane.goBack() } }
                }
            }
        } else if !pane.isLoading && pane.visibleItems.isEmpty {
            ContentUnavailableView {
                Label(pane.searchText.isEmpty ? "Empty folder" : "No matches",
                      systemImage: pane.searchText.isEmpty ? "folder" : "magnifyingglass")
            } description: {
                Text(pane.searchText.isEmpty
                     ? (pane.side == .phone ? "Drop files here to copy them to your phone." : "Drop phone files here to copy them to this folder.")
                     : "Nothing in this folder matches “\(pane.searchText)”.")
            }
        } else if pane.viewMode == .list {
            FileTable(pane: pane)
        } else {
            FileGrid(pane: pane)
        }
    }
}

// MARK: - Header

private struct PaneHeader: View {
    @Environment(AppModel.self) private var app
    @Bindable var pane: PaneModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pane.side == .mac ? "laptopcomputer" : "smartphone")
                .foregroundStyle(.secondary)
                .help(pane.side == .mac ? "This Mac" : (app.selectedDevice?.displayName ?? "Phone"))
            ControlGroup {
                Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!pane.canGoBack).help("Back")
                Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!pane.canGoForward).help("Forward")
            }
            .fixedSize()
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.canGoUp).help("Enclosing folder")
                .buttonStyle(.borderless)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(crumb.0) { pane.navigate(to: crumb.1) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(index == pane.breadcrumbs.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)

            Spacer(minLength: 4)

            TextField("Search", text: $pane.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)

            Picker("View", selection: $pane.viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List or icon view")

            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .disabled(pane.side == .phone && !app.isPhoneReady)
    }
}

// MARK: - Footer

private struct PaneFooter: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel

    var body: some View {
        HStack(spacing: 8) {
            let count = pane.visibleItems.count
            Text("\(count) item\(count == 1 ? "" : "s")" + (pane.selection.isEmpty ? "" : ", \(pane.selection.count) selected"))
            if pane.side == .phone && app.isPhoneReady && !SafetyPolicy.isWritableLocation(pane.path) {
                Label("Read-only system location", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if pane.isLoading && !pane.items.isEmpty { ProgressView().controlSize(.mini) }
            if let s = pane.storage {
                Text("\(Format.size(s.availableBytes)) available of \(Format.size(s.totalBytes))")
                ProgressView(value: s.fractionUsed)
                    .frame(width: 60)
                    .tint(s.fractionUsed > 0.9 ? .red : .accentColor)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - Drag and drop

/// Mac pane accepts phone items (download). Phone pane accepts file URLs from the Mac
/// pane or Finder (upload).
private struct DropTargetModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        Group {
            if pane.side == .mac {
                content.dropDestination(for: RemoteDragItem.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    app.download(remotePaths: items.map(\.path), to: pane.path)
                    return true
                } isTargeted: { isTargeted = $0 }
            } else {
                content.dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty, app.isPhoneReady else { return false }
                    app.upload(urls: files, to: pane.path)
                    return true
                } isTargeted: { isTargeted = $0 && app.isPhoneReady }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
func dragProvider(for item: FileItem, side: PaneSide, serial: String?) -> NSItemProvider {
    switch side {
    case .mac:
        return NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
    case .phone:
        let provider = NSItemProvider()
        let payload = RemoteDragItem(serial: serial ?? "", path: item.path)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pixelBridgeRemoteItem.identifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = item.name
        return provider
    }
}

// MARK: - Shared context menu

struct FileContextMenu: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let ids: Set<String>

    var body: some View {
        let items = pane.items.filter { ids.contains($0.path) }
        if items.count == 1, let item = items.first {
            Button("Open") { app.open(item, on: pane.side) }
            if !item.isDirectory {
                Button("Quick Look") { pane.selection = ids; app.quickLook(on: pane.side) }
            }
            Divider()
        }
        if !items.isEmpty {
            Button(pane.side == .mac ? "Copy to Phone" : "Copy to Mac") {
                app.transfer(from: pane.side, items: items)
            }
            .disabled(!app.isPhoneReady)
            Button(pane.side == .mac ? "Move to Phone" : "Move to Mac") {
                app.transfer(from: pane.side, items: items, operation: .move)
            }
            .disabled(!app.isPhoneReady)
            Divider()
            Button("Copy") { pane.selection = ids; app.copySelection(on: pane.side) }
        }
        Button("Paste") { app.paste(on: pane.side) }
            .disabled(!app.canPaste(on: pane.side))
        Divider()
        if items.count == 1 {
            Button("Rename…") { pane.selection = ids; app.requestRename(on: pane.side) }
        }
        Button("New Folder") { app.requestNewFolder(on: pane.side) }
        if pane.side == .mac, items.count >= 1 {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
            }
        }
        if !items.isEmpty {
            Divider()
            Button(pane.side == .mac ? "Move to Trash" : "Delete…", role: .destructive) {
                pane.selection = ids
                app.requestDelete(on: pane.side)
            }
        }
    }
}
