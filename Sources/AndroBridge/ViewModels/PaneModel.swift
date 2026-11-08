import AppKit
import Foundation
import Observation
import AndroBridgeCore

enum PaneSide: String {
    case mac
    case phone
}

enum ViewMode: String {
    case list
    case grid
}

enum SortKey: String, CaseIterable {
    case name, size, kind, modified
}

/// State for one side of the dual-pane browser.
@MainActor
@Observable
final class PaneModel {
    let side: PaneSide
    private(set) var path: String
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var storage: StorageInfo?
    var selection: Set<String> = []
    var searchText = ""
    var viewMode: ViewMode = .list
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]
    var foldersFirst = true

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var loadTask: Task<Void, Never>?

    /// Where to read files from. Set by AppModel.
    var lister: ((String) async throws -> [FileItem])?
    var storageReader: ((String) async -> StorageInfo?)?
    var showHidden: () -> Bool = { false }
    /// Called with the new path after every navigation (used to remember the last Mac folder).
    var onNavigate: ((String) -> Void)?

    init(side: PaneSide, path: String) {
        self.side = side
        self.path = path
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { parent(of: path) != path }

    /// Items after hidden-file filtering, search and sorting.
    var visibleItems: [FileItem] {
        var list = items
        if !showHidden() { list = list.filter { !$0.isHidden } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        list.sort(using: sortOrder)
        if foldersFirst {
            list = list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
        }
        return list
    }

    /// Selected items in on-screen order, so transfers queue in the order you see them.
    var selectedItems: [FileItem] {
        visibleItems.filter { selection.contains($0.path) }
    }

    func navigate(to newPath: String, recordHistory: Bool = true) {
        if recordHistory && newPath != path {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        selection = []
        searchText = ""
        onNavigate?(newPath)
        reload()
    }

    /// Changes the path without touching history (e.g. when the device changes).
    func reset(to newPath: String) {
        backStack.removeAll()
        forwardStack.removeAll()
        path = newPath
        items = []
        selection = []
        reload()
    }

    func clear(error message: String?) {
        loadTask?.cancel()
        items = []
        selection = []
        storage = nil
        error = message
        isLoading = false
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(path)
        navigate(to: prev, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        let p = parent(of: path)
        if p != path { navigate(to: p) }
    }

    func open(_ item: FileItem) -> Bool {
        guard item.isDirectory else { return false }
        navigate(to: item.path)
        return true
    }

    func reload() {
        loadTask?.cancel()
        guard let lister else { return }
        let target = path
        isLoading = true
        error = nil
        loadTask = Task { [weak self] in
            do {
                let result = try await lister(target)
                guard let self, !Task.isCancelled, self.path == target else { return }
                self.items = result
                // Keep selection only for items that still exist.
                let existing = Set(result.map(\.path))
                self.selection = self.selection.intersection(existing)
                self.isLoading = false
                self.storage = await self.storageReader?(target)
            } catch is CancellationError {
            } catch {
                guard let self, self.path == target else { return }
                self.items = []
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Breadcrumb segments: (label, path).
    var breadcrumbs: [(String, String)] {
        switch side {
        case .phone:
            var result: [(String, String)] = []
            var acc = ""
            for comp in RemotePath.components(path) {
                acc += "/" + comp
                result.append((comp == "sdcard" ? "Internal storage" : comp, acc))
            }
            return result.isEmpty ? [("/", "/")] : result
        case .mac:
            // Build from path components; walking up with URL.deletingLastPathComponent
            // goes past "/" to "/..".
            var result: [(String, String)] = [(FileManager.default.displayName(atPath: "/"), "/")]
            var acc = ""
            for comp in URL(fileURLWithPath: path).standardizedFileURL.pathComponents where comp != "/" {
                acc += "/" + comp
                result.append((FileManager.default.displayName(atPath: acc), acc))
            }
            return result
        }
    }

    private func parent(of p: String) -> String {
        switch side {
        case .phone: return RemotePath.parent(p)
        case .mac: return URL(fileURLWithPath: p).deletingLastPathComponent().path
        }
    }

    func childPath(_ name: String) -> String {
        switch side {
        case .phone: return RemotePath.join(path, name)
        case .mac: return URL(fileURLWithPath: path).appendingPathComponent(name).path
        }
    }
}
