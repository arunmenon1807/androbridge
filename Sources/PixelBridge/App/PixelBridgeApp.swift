import AppKit
import PixelBridgeCore
import SwiftUI

@main
struct PixelBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("PixelBridge", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.start() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands { PixelBridgeCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from `swift run` there is no bundle; make it a regular app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.clearPreviewCache()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PixelBridgeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { model.requestNewFolder(on: model.activeSide) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename…") { model.requestRename(on: model.activeSide) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Delete…") { model.requestDelete(on: model.activeSide) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Back") { model.activePane.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.activePane.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("Enclosing Folder") { model.activePane.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Open") {
                if let item = model.activePane.selectedItems.first { model.open(item, on: model.activeSide) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Phone Internal Storage") { model.activeSide = .phone; model.phonePane.navigate(to: "/sdcard") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Phone Camera (DCIM)") { model.activeSide = .phone; model.phonePane.navigate(to: "/sdcard/DCIM") }
            Button("Mac Downloads") {
                model.activeSide = .mac
                model.macPane.navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Switch Pane") { model.activeSide = model.activeSide == .mac ? .phone : .mac }
                .keyboardShortcut("\\", modifiers: .command)
        }
        CommandMenu("Transfer") {
            Button("Copy to Phone") { model.transfer(from: .mac, items: model.macPane.selectedItems) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Button("Copy to Mac") { model.transfer(from: .phone, items: model.phonePane.selectedItems) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Divider()
            Button("Move to Phone") { model.transfer(from: .mac, items: model.macPane.selectedItems, operation: .move) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift, .option])
            Button("Move to Mac") { model.transfer(from: .phone, items: model.phonePane.selectedItems, operation: .move) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift, .option])
            Divider()
            Button("Cancel All Transfers") { model.queue.cancelAll() }
            Button("Show Transfers") { model.showTransferPanel.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Connect over Wi-Fi…") { model.showWirelessSheet = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { model.macPane.reload(); model.phonePane.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("as List") { model.activePane.viewMode = .list }.keyboardShortcut("1", modifiers: .command)
            Button("as Icons") { model.activePane.viewMode = .grid }.keyboardShortcut("2", modifiers: .command)
            Button("Show Hidden Files") { model.settings.showHiddenFiles.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }
    }
}
