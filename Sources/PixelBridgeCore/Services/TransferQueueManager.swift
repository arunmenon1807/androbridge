import Foundation
import Observation

public enum TransferStatus: Equatable, Sendable {
    case queued
    case running(TransferPhase)
    case completed(VerificationLevel)
    case completedSourceKept(String)
    case skipped
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        default: return true
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        if case .cancelled = self { return true }
        return false
    }
}

/// One row in the transfer activity panel.
@MainActor
@Observable
public final class TransferItem: Identifiable {
    public let id: UUID
    public let request: TransferRequest
    public internal(set) var status: TransferStatus = .queued
    public internal(set) var bytesDone: Int64 = 0
    public internal(set) var totalBytes: Int64 = 0
    /// Bytes per second, smoothed.
    public internal(set) var speed: Double = 0
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var finalPath: String?

    fileprivate var task: Task<Void, Never>?
    fileprivate var lastSample: (Date, Int64)?

    init(request: TransferRequest) {
        self.id = request.id
        self.request = request
    }

    public var fractionDone: Double {
        totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : 0
    }

    /// Estimated seconds remaining, or nil if unknown.
    public var secondsRemaining: Double? {
        guard speed > 1, totalBytes > bytesDone else { return nil }
        return Double(totalBytes - bytesDone) / speed
    }

    fileprivate func record(bytes: Int64, total: Int64, phase: TransferPhase) {
        // Progress callbacks hop to the main actor and can arrive after the item finished.
        guard !status.isFinished else { return }
        if total > 0 { totalBytes = total }
        status = .running(phase)
        let now = Date()
        if phase == .transferring, let (t0, b0) = lastSample, bytes >= b0 {
            let dt = now.timeIntervalSince(t0)
            if dt >= 0.3 {
                let instant = Double(bytes - b0) / dt
                speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3
                lastSample = (now, bytes)
            }
        } else if lastSample == nil {
            lastSample = (now, bytes)
        }
        bytesDone = max(bytesDone, bytes)
    }
}

/// Runs transfers one at a time (adb serializes per device anyway) and keeps history.
@MainActor
@Observable
public final class TransferQueueManager {
    public private(set) var items: [TransferItem] = []
    public private(set) var history: [TransferHistoryEntry] = []

    /// Resolves a serial to a live connection. Returns nil if the device is gone.
    public var deviceProvider: (String) -> DeviceConnection? = { _ in nil }
    /// Asked when a destination already exists.
    public var conflictHandler: FileTransferService.ConflictHandler = { _ in .keepBoth }
    public var optionsProvider: () -> TransferOptions = { TransferOptions() }
    /// Called after each transfer finishes, so browsers can refresh.
    public var onItemFinished: ((TransferItem) -> Void)?

    private let engine = FileTransferService()
    private var runner: Task<Void, Never>?
    private let historyStore: TransferHistoryStore

    public init(historyStore: TransferHistoryStore = TransferHistoryStore()) {
        self.historyStore = historyStore
        self.history = historyStore.load()
    }

    public var activeItems: [TransferItem] { items.filter { !$0.status.isFinished } }
    public var hasActiveTransfers: Bool { items.contains { !$0.status.isFinished } }

    public func enqueue(_ requests: [TransferRequest]) {
        for r in requests { items.append(TransferItem(request: r)) }
        startRunnerIfNeeded()
    }

    public func cancel(_ item: TransferItem) {
        if case .queued = item.status {
            item.status = .cancelled
            item.finishedAt = Date()
            appendHistory(item)
        } else {
            item.task?.cancel()
        }
    }

    public func cancelAll() {
        for item in items where !item.status.isFinished { cancel(item) }
    }

    public func retry(_ item: TransferItem) {
        enqueue([item.request.retried()])
    }

    public func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    public func clearHistory() {
        history = []
        historyStore.save(history)
    }

    private func startRunnerIfNeeded() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let next = self.items.first(where: { if case .queued = $0.status { return true }; return false }) {
                await self.run(next)
            }
            self?.runner = nil
        }
    }

    private func run(_ item: TransferItem) async {
        guard let device = deviceProvider(item.request.deviceSerial) else {
            finish(item, .failed(DeviceError.deviceDisconnected.localizedDescription))
            return
        }
        item.startedAt = Date()
        item.status = .running(.preparing)
        let engine = self.engine
        let options = optionsProvider()
        let onConflict = conflictHandler
        let request = item.request
        let task = Task { [weak self] in
            do {
                let outcome = try await engine.perform(request, device: device, options: options, onConflict: onConflict) { done, total, phase in
                    Task { @MainActor in item.record(bytes: done, total: total, phase: phase) }
                }
                await MainActor.run {
                    switch outcome {
                    case .completed(let path, let bytes, let level):
                        item.finalPath = path
                        item.totalBytes = bytes
                        item.bytesDone = bytes
                        self?.finish(item, .completed(level))
                    case .copiedSourceKept(let path, let bytes, let reason):
                        item.finalPath = path
                        item.totalBytes = bytes
                        item.bytesDone = bytes
                        self?.finish(item, .completedSourceKept(reason))
                    case .skipped:
                        self?.finish(item, .skipped)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self?.finish(item, .cancelled) }
            } catch let error as ProcessRunnerError where error == .timedOut {
                await MainActor.run { self?.finish(item, .failed(error.localizedDescription)) }
            } catch {
                let cancelled = Task.isCancelled
                await MainActor.run {
                    self?.finish(item, cancelled ? .cancelled : .failed(error.localizedDescription))
                }
            }
        }
        item.task = task
        await task.value
    }

    private func finish(_ item: TransferItem, _ status: TransferStatus) {
        item.status = status
        item.finishedAt = Date()
        item.task = nil
        appendHistory(item)
        onItemFinished?(item)
    }

    private func appendHistory(_ item: TransferItem) {
        history.insert(TransferHistoryEntry(item: item), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        historyStore.save(history)
    }
}

/// A finished transfer, persisted as JSON in Application Support.
public struct TransferHistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let request: TransferRequest
    public let outcome: String
    public let succeeded: Bool
    public let bytes: Int64
    public let finishedAt: Date
    public let finalPath: String?

    @MainActor
    init(item: TransferItem) {
        id = item.id
        request = item.request
        bytes = item.totalBytes
        finishedAt = item.finishedAt ?? Date()
        finalPath = item.finalPath
        switch item.status {
        case .completed(let level):
            outcome = level == .sha256 ? "Completed (SHA-256 verified)" : "Completed (size verified)"
            succeeded = true
        case .completedSourceKept(let why):
            outcome = "Copied; original kept: \(why)"
            succeeded = true
        case .skipped:
            outcome = "Skipped"
            succeeded = true
        case .failed(let why):
            outcome = "Failed: \(why)"
            succeeded = false
        case .cancelled:
            outcome = "Cancelled"
            succeeded = false
        case .queued, .running:
            outcome = "Unknown"
            succeeded = false
        }
    }
}

public struct TransferHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PixelBridge", isDirectory: true)
            self.fileURL = base.appendingPathComponent("transfer-history.json")
        }
    }

    public func load() -> [TransferHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TransferHistoryEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [TransferHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
