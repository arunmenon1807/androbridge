import Foundation

/// The result of running a subprocess to completion.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

/// Runs a subprocess with an explicit argument vector.
///
/// Arguments are passed straight to `execve` through `Process`; no local shell is ever
/// involved, so file names with spaces, quotes or `$` cannot be reinterpreted on the Mac.
/// (Commands that run *on the phone* go through `adb shell`, which does use a remote shell;
/// those are quoted with `ShellQuoting`.)
public final class ProcessRunner: @unchecked Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Runs the process and waits for it. Cancelling the calling task terminates the process.
    public func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Keep adb's own environment predictable and never inherit a TTY.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let box = OutputBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { box.appendOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { box.appendErr(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain anything left in the pipes.
                    box.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    box.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if box.timedOut {
                        cont.resume(throwing: ProcessRunnerError.timedOut)
                    } else if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            stdout: box.out,
                            stderr: box.err
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            box.timedOut = true
                            process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            box.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let why): return "Could not start adb: \(why)"
        case .timedOut: return "The operation timed out."
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    private var _cancelled = false
    private var _timedOut = false

    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }
    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }
    func appendOut(_ d: Data) { lock.withLock { _out.append(d) } }
    func appendErr(_ d: Data) { lock.withLock { _err.append(d) } }
}
