import AndroBridgeCore
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let banner = app.banner {
                    HStack {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        Text(banner).font(.callout)
                        Spacer()
                        Button { app.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.orange.opacity(0.12))
                }
                VSplitView {
                    HSplitView {
                        PaneView(pane: app.macPane)
                            .frame(minWidth: 320)
                        PaneView(pane: app.phonePane)
                            .frame(minWidth: 320)
                    }
                    .frame(minHeight: 260)
                    if app.showTransferPanel {
                        TransferPanelView()
                            .frame(minHeight: 120, idealHeight: 180, maxHeight: 400)
                    }
                }
            }
        }
        .navigationTitle(app.selectedDevice.map { "AndroBridge — \($0.displayName)" } ?? "AndroBridge")
        .toolbar { toolbar }
        .quickLookPreview($app.previewURL)
        .sheet(item: $app.conflictPrompt) { ConflictSheet(prompt: $0) }
        .sheet(item: $app.nameRequest) { NameSheet(request: $0) }
        .sheet(isPresented: $app.showWirelessSheet) { WirelessSheet() }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { app.deleteRequest != nil }, set: { if !$0 { app.deleteRequest = nil } }),
                            titleVisibility: .visible, presenting: app.deleteRequest) { req in
            Button(req.side == .mac ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                app.confirmDelete(req)
            }
            Button("Cancel", role: .cancel) {}
        } message: { req in
            Text(req.side == .mac
                 ? "You can restore items from the Trash."
                 : "Files deleted from the phone can’t be recovered.\n" + req.items.prefix(5).map(\.name).joined(separator: "\n") + (req.items.count > 5 ? "\n…and \(req.items.count - 5) more" : ""))
        }
        .alert("AndroBridge", isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            if app.isPreparingPreview {
                HStack { ProgressView().controlSize(.small); Text("Fetching from phone…") }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    private var deleteTitle: String {
        guard let req = app.deleteRequest else { return "" }
        let what = req.items.count == 1 ? "“\(req.items[0].name)”" : "\(req.items.count) items"
        return req.side == .mac ? "Move \(what) to the Trash?" : "Delete \(what) from the phone?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.transfer(from: .phone, items: app.phonePane.selectedItems)
            } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Copy selected phone items to the Mac folder (⇧⌘←)")
            .disabled(!app.isPhoneReady || app.phonePane.selection.isEmpty)

            Button {
                app.transfer(from: .mac, items: app.macPane.selectedItems)
            } label: {
                Label("Copy to Phone", systemImage: "square.and.arrow.up.on.square")
            }
            .help("Copy selected Mac items to the phone folder (⇧⌘→)")
            .disabled(!app.isPhoneReady || app.macPane.selection.isEmpty)

            Button {
                app.requestNewFolder(on: app.activeSide)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New folder in the active pane (⇧⌘N)")

            Button {
                app.requestDelete(on: app.activeSide)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selected items in the active pane (⌘⌫)")
            .disabled(app.activePane.selection.isEmpty)

            Button {
                app.showTransferPanel.toggle()
            } label: {
                Label("Transfers", systemImage: app.queue.hasActiveTransfers ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .help("Show or hide transfers")
        }
    }
}
