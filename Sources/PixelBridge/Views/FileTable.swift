import AppKit
import PixelBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style list view with sortable columns and multi-selection.
struct FileTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var pane: PaneModel

    var body: some View {
        let serial = app.selectedSerial
        let side = pane.side
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(item.isHidden ? 0.6 : 1)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Date Modified", value: \.modifiedSortKey) { item in
                Text(item.modified.map { Format.date.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Size", value: \.sizeSortKey) { item in
                Text(item.isDirectory ? "—" : Format.size(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 80)
            TableColumn("Kind", value: \.kindDescription) { item in
                Text(item.kindDescription).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 110)
        } rows: {
            ForEach(pane.visibleItems) { item in
                TableRow(item)
                    .itemProvider { dragProvider(for: item, side: side, serial: serial) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileContextMenu(pane: pane, ids: ids)
        } primaryAction: { ids in
            // Double-click or Return.
            if ids.count == 1, let item = pane.items.first(where: { ids.contains($0.path) }) {
                app.open(item, on: side)
            }
        }
        .onChange(of: pane.selection) { _, new in
            if !new.isEmpty { app.activeSide = side }
        }
        .onKeyPress(.space) {
            app.quickLook(on: side)
            return .handled
        }
        .onDeleteCommand { app.requestDelete(on: side) }
        .onCopyCommand {
            app.copySelection(on: side)
            return pane.selectedItems.map { dragProvider(for: $0, side: side, serial: serial) }
        }
        .onPasteCommand(of: [.fileURL, .pixelBridgeRemoteItem]) { _ in
            app.paste(on: side)
        }
    }
}

/// Icon view.
struct FileGrid: View {
    @Environment(AppModel.self) private var app
    @Bindable var pane: PaneModel

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    var body: some View {
        let serial = app.selectedSerial
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(pane.visibleItems) { item in
                    let selected = pane.selection.contains(item.path)
                    VStack(spacing: 4) {
                        Image(nsImage: IconCache.icon(for: item))
                            .resizable()
                            .frame(width: 48, height: 48)
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                            .padding(.horizontal, 3)
                            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .frame(width: 96, height: 92)
                    .background(selected ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { app.open(item, on: pane.side) }
                    .onTapGesture { select(item) }
                    .onDrag { dragProvider(for: item, side: pane.side, serial: serial) }
                    .contextMenu {
                        FileContextMenu(pane: pane, ids: selected ? pane.selection : [item.path])
                    }
                }
            }
            .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture { pane.selection = [] }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            app.quickLook(on: pane.side)
            return .handled
        }
        .onDeleteCommand { app.requestDelete(on: pane.side) }
    }

    private func select(_ item: FileItem) {
        app.activeSide = pane.side
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if pane.selection.contains(item.path) { pane.selection.remove(item.path) } else { pane.selection.insert(item.path) }
        } else if mods.contains(.shift), let anchor = pane.visibleItems.firstIndex(where: { pane.selection.contains($0.path) }),
                  let idx = pane.visibleItems.firstIndex(of: item) {
            let range = min(anchor, idx)...max(anchor, idx)
            pane.selection = Set(pane.visibleItems[range].map(\.path))
        } else {
            pane.selection = [item.path]
        }
    }
}
