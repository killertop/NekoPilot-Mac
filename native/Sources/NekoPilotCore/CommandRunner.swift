import Foundation
import Darwin

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let errorOutput: String
}

enum CommandRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        let completion = ProcessCompletion()
        process.terminationHandler = { terminated in
            completion.finish(terminated.terminationStatus)
        }
        try process.run()
        // A very short-lived command can finish before Foundation delivers the
        // termination callback. Preserve that result instead of leaving the
        // caller waiting on a callback that will never arrive.
        if !process.isRunning {
            completion.finish(process.terminationStatus)
        }
        // `Pipe` keeps a parent-side writer open as well as the descriptor
        // inherited by the child. If the parent copy stays open,
        // readDataToEndOfFile can wait forever after a short command exits.
        // Closing only the parent writers makes EOF deterministic while the
        // child continues using its inherited descriptors.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        // Drain both pipes while the child is running. Waiting first can
        // deadlock once either kernel pipe buffer fills (configuration checks
        // and networksetup both run through this helper).
        let outputTask = Task.detached(priority: .utility) {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            errors.fileHandleForReading.readDataToEndOfFile()
        }

        let outcome = await withTaskCancellationHandler {
            await waitForExit(completion, timeout: max(0.1, timeout))
        } onCancel: {
            terminate(process)
            completion.cancelWaiter()
        }
        guard !outcome.timedOut else {
            // Do not wait for Foundation's `waitUntilExit()` equivalent after
            // a timeout. It can remain blocked even after macOS has reaped a
            // networksetup child, which previously left the UI in
            // "正在连接" forever. Do not close the readers here: both detached
            // tasks may still be blocked in Foundation's FileHandle read, and
            // concurrently closing the same descriptor can raise an
            // NSFileHandleOperationException that Swift cannot catch. The
            // child termination below closes its inherited writers, allowing
            // both drain tasks to finish normally at EOF.
            terminate(process)
            throw NekoPilotError.processFailed(CoreL10n.text("命令执行超时", "The command timed out"))
        }
        let outData = await outputTask.value
        let errorData = await errorTask.value
        guard !Task.isCancelled else { throw CancellationError() }
        return CommandResult(
            status: outcome.status,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }

    private static func waitForExit(
        _ completion: ProcessCompletion,
        timeout: TimeInterval
    ) async -> (status: Int32, timedOut: Bool) {
        await withTaskGroup(of: (Int32?, Bool).self) { group in
            group.addTask {
                (await completion.wait(), false)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return (nil, false)
                }
                return (nil, true)
            }

            while let first = await group.next() {
                if let status = first.0 {
                    group.cancelAll()
                    completion.cancelWaiter()
                    return (status, false)
                }
                if first.1 {
                    group.cancelAll()
                    completion.cancelWaiter()
                    return (0, true)
                }
            }
            return (0, true)
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // SIGTERM is cooperative. A delayed SIGKILL bounds cancellation even
        // when the child is stuck before installing its signal handler.
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}

/// `Process.waitUntilExit()` can become detached from the child on macOS when
/// a command is terminated while SystemConfiguration is busy.  A dedicated,
/// cancellation-aware completion keeps callers responsive and ensures the
/// startup state always reaches either running or failed.
private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32?, Never>?
    private var waitCancelled = false

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else if waitCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiter()
        }
    }

    func cancelWaiter() {
        lock.lock()
        waitCancelled = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}
