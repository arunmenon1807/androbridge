import AppKit
import AndroBridgeCore
import SwiftUI

/// Bottom panel: current and finished transfers, plus persistent history.
struct TransferPanelView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Transfers").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab == 0 {
                    if app.queue.hasActiveTransfers {
                        Button("Cancel All") { app.queue.cancelAll() }
                    }
                    Button("Clear Finished") { app.queue.clearFinished() }
                        .disabled(!app.queue.items.contains { $0.status.isFinished })
                } else {
                    Button("Clear History") { app.queue.clearHistory() }
                        .disabled(app.queue.history.isEmpty)
                }
                Button {
                    app.showTransferPanel = false
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide transfers")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if tab == 0 { current } else { history }
        }
    }

    @ViewBuilder
    private var current: some View {
        if app.queue.items.isEmpty {
            Text("Drag files between the panes, or select files and press ⇧⌘→ / ⇧⌘←.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(app.queue.items.reversed()) { item in
                TransferRow(item: item)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var history: some View {
        if app.queue.history.isEmpty {
            Text("No transfers yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(app.queue.history) { entry in
                HStack {
                    Image(systemName: entry.request.direction == .toMac ? "arrow.down.to.line" : "arrow.up.to.line")
                        .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.request.displayName).lineLimit(1)
                        Text("\(entry.outcome) · \(Format.size(entry.bytes)) · \(Format.date.string(from: entry.finishedAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let p = entry.finalPath, entry.request.direction == .toMac, FileManager.default.fileExists(atPath: p) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var app
    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.request.direction == .toMac ? "arrow.down.to.line" : "arrow.up.to.line")
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.request.displayName).lineLimit(1).truncationMode(.middle)
                    if item.request.operation == .move {
                        Text("MOVE").font(.caption2.bold()).foregroundStyle(.orange)
                    }
                }
                if case .running = item.status {
                    ProgressView(value: item.fractionDone)
                        .progressViewStyle(.linear)
                }
                Text(detail).font(.caption).foregroundStyle(item.status.isFailure ? .red : .secondary).lineLimit(2)
            }
            Spacer()
            switch item.status {
            case .queued, .running:
                Button { app.queue.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel")
            case .failed, .cancelled:
                Button("Retry") { app.queue.retry(item) }.controlSize(.small)
            case .completed, .completedSourceKept:
                if let p = item.finalPath, item.request.direction == .toMac {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless).help("Show in Finder")
                }
            case .skipped:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch item.status {
        case .completed, .completedSourceKept: return .green
        case .failed, .cancelled: return .red
        default: return .accentColor
        }
    }

    private var detail: String {
        let dest = item.request.direction == .toMac
            ? "to \((item.request.destinationDirectory as NSString).lastPathComponent)"
            : "to \(item.request.deviceName): \(RemotePath.name(item.request.destinationDirectory))"
        switch item.status {
        case .queued: return "Waiting · \(dest)"
        case .running(let phase):
            switch phase {
            case .preparing: return "Preparing…"
            case .verifying: return "Verifying copy…"
            case .finishing: return "Finishing…"
            case .transferring:
                var parts = ["\(Format.size(item.bytesDone)) of \(Format.size(item.totalBytes))"]
                if item.speed > 0 { parts.append(Format.speed(item.speed)) }
                if let eta = item.secondsRemaining { parts.append("\(Format.duration(eta)) left") }
                return parts.joined(separator: " · ")
            }
        case .completed(let level):
            return "Done · \(Format.size(item.totalBytes)) · " + (level == .sha256 ? "SHA-256 verified" : "size verified")
        case .completedSourceKept(let why):
            return "Copied and verified, but the original couldn’t be removed: \(why)"
        case .skipped: return "Skipped (already exists)"
        case .failed(let why): return why
        case .cancelled: return "Cancelled. Nothing was left half-copied."
        }
    }
}
