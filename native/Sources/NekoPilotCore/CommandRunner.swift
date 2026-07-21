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
        try process.run()
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
            await waitForExit(process, timeout: max(0.1, timeout))
        } onCancel: {
            terminate(process)
        }
        let outData = await outputTask.value
        let errorData = await errorTask.value
        guard !outcome.timedOut else {
            throw NekoPilotError.processFailed("命令执行超时")
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return CommandResult(
            status: outcome.status,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }

    private static func waitForExit(
        _ process: Process,
        timeout: TimeInterval
    ) async -> (status: Int32, timedOut: Bool) {
        await withTaskGroup(of: (Int32?, Bool).self) { group in
            group.addTask {
                process.waitUntilExit()
                return (process.terminationStatus, false)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    // Cancellation must use the same cleanup path as timeout.
                }
                return (nil, true)
            }

            guard let first = await group.next() else {
                terminate(process)
                return (process.terminationStatus, true)
            }
            if let status = first.0 {
                group.cancelAll()
                return (status, false)
            }

            terminate(process)
            // The waitUntilExit task drains after SIGTERM/SIGKILL. Keeping it
            // in the group guarantees Process and its pipes cannot outlive the
            // call and become an orphan URL-test/check process.
            while let next = await group.next() {
                if let status = next.0 { return (status, true) }
            }
            return (process.terminationStatus, true)
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
