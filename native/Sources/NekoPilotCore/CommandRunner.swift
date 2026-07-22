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
        let command = try spawn(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        let completion = ProcessCompletion()
        let drains = PipeDrainCompletion()
        let outputTask = startPipeDrain(
            descriptor: command.outputDescriptor,
            stream: .output,
            completion: drains
        )
        let errorTask = startPipeDrain(
            descriptor: command.errorDescriptor,
            stream: .error,
            completion: drains
        )

        // Reap independently of the caller. Cancellation and timeout signal the
        // owned process group, so this waiter will also complete on those paths.
        Task.detached(priority: .utility) {
            completion.finish(waitForProcess(command.pid))
        }

        let allowedDuration = max(0.1, timeout)
        let deadline = monotonicDeadline(after: allowedDuration)
        let exitOutcome = await withTaskCancellationHandler {
            await waitForExit(completion, timeout: allowedDuration)
        } onCancel: {
            command.signalGroup(SIGKILL)
            completion.cancelWaiter()
            drains.cancelWaiter()
            outputTask.cancel()
            errorTask.cancel()
        }

        if Task.isCancelled {
            await stop(command, outputTask: outputTask, errorTask: errorTask)
            throw CancellationError()
        }
        guard !exitOutcome.timedOut else {
            await stop(command, outputTask: outputTask, errorTask: errorTask)
            if Task.isCancelled { throw CancellationError() }
            throw timeoutError()
        }

        // A direct child can exit while one of its descendants still owns an
        // inherited stdout/stderr writer. Pipe draining shares the command's
        // original deadline instead of extending it without a bound.
        let remaining = remainingTime(until: deadline)
        let drainOutcome = await withTaskCancellationHandler {
            await waitForDrains(drains, timeout: remaining)
        } onCancel: {
            command.signalGroup(SIGKILL)
            drains.cancelWaiter()
            outputTask.cancel()
            errorTask.cancel()
        }

        if Task.isCancelled {
            await stop(command, outputTask: outputTask, errorTask: errorTask)
            throw CancellationError()
        }
        guard let drained = drainOutcome.data else {
            await stop(command, outputTask: outputTask, errorTask: errorTask)
            if Task.isCancelled { throw CancellationError() }
            throw timeoutError()
        }

        return CommandResult(
            status: exitOutcome.status,
            output: String(decoding: drained.output, as: UTF8.self),
            errorOutput: String(decoding: drained.error, as: UTF8.self)
        )
    }

    private static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> SpawnedCommand {
        try ProcessSpawnGate.withLock {
            try spawnLocked(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        }
    }

    private static func spawnLocked(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> SpawnedCommand {
        var outputDescriptors: [Int32] = [0, 0]
        var errorDescriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&outputDescriptors) == 0 else { throw posixError(errno) }
        guard setCloseOnExec(outputDescriptors) else {
            outputDescriptors.forEach { close($0) }
            throw posixError(errno)
        }
        guard Darwin.pipe(&errorDescriptors) == 0 else {
            close(outputDescriptors[0])
            close(outputDescriptors[1])
            throw posixError(errno)
        }
        guard setCloseOnExec(errorDescriptors) else {
            outputDescriptors.forEach { close($0) }
            errorDescriptors.forEach { close($0) }
            throw posixError(errno)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionsInitialized = false
        var attributesInitialized = false
        defer {
            if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        }

        var setupError = posix_spawn_file_actions_init(&actions)
        if setupError == 0 { actionsInitialized = true }
        if setupError == 0 { setupError = posix_spawn_file_actions_adddup2(&actions, outputDescriptors[1], STDOUT_FILENO) }
        if setupError == 0 { setupError = posix_spawn_file_actions_adddup2(&actions, errorDescriptors[1], STDERR_FILENO) }
        for descriptor in outputDescriptors + errorDescriptors where setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if setupError == 0 {
            setupError = posix_spawnattr_init(&attributes)
            if setupError == 0 { attributesInitialized = true }
        }
        if setupError == 0 { setupError = posix_spawnattr_setpgroup(&attributes, 0) }
        if setupError == 0 {
            let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            setupError = posix_spawnattr_setflags(&attributes, Int16(spawnFlags))
        }
        guard setupError == 0 else {
            outputDescriptors.forEach { close($0) }
            errorDescriptors.forEach { close($0) }
            throw posixError(setupError)
        }

        let argumentStrings = [executable.path] + arguments
        let environmentStrings = (environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnError = withCStringArray(argumentStrings) { argumentPointers in
            withCStringArray(environmentStrings) { environmentPointers in
                executable.path.withCString { path in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }

        close(outputDescriptors[1])
        close(errorDescriptors[1])
        guard spawnError == 0 else {
            close(outputDescriptors[0])
            close(errorDescriptors[0])
            throw posixError(spawnError)
        }

        let nonBlockingError = setNonBlocking(outputDescriptors[0])
            ?? setNonBlocking(errorDescriptors[0])
        if let nonBlockingError {
            // The drain tasks rely on non-blocking reads to observe their own
            // cancellation. Do not return a command whose reader could make
            // timeout cleanup wait forever.
            _ = kill(-pid, SIGKILL)
            close(outputDescriptors[0])
            close(errorDescriptors[0])
            _ = waitForProcess(pid)
            throw posixError(nonBlockingError)
        }
        return SpawnedCommand(
            pid: pid,
            outputDescriptor: outputDescriptors[0],
            errorDescriptor: errorDescriptors[0]
        )
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) as UnsafeMutablePointer<CChar>? }
        pointers.append(nil)
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Int32? {
        let flags = fcntl(descriptor, F_GETFL)
        if flags < 0 { return errno }
        if fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 { return errno }
        return nil
    }

    private static func setCloseOnExec(_ descriptors: [Int32]) -> Bool {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 {
                return false
            }
        }
        return true
    }

    private static func monotonicDeadline(after duration: TimeInterval) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let capacity = UInt64.max - now
        guard duration.isFinite else { return UInt64.max }
        let scaled = max(0, duration) * 1_000_000_000
        guard scaled < Double(capacity) else { return UInt64.max }
        let nanoseconds = UInt64(scaled)
        return now + nanoseconds
    }

    private static func remainingTime(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private static func nanoseconds(for duration: TimeInterval) -> UInt64 {
        guard duration.isFinite else { return UInt64.max }
        let scaled = max(0, duration) * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled)
    }

    private static func startPipeDrain(
        descriptor: Int32,
        stream: PipeStream,
        completion: PipeDrainCompletion
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            defer {
                close(descriptor)
                completion.finish(stream: stream, data: data)
            }
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(Int(count)))
                } else if count == 0 {
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                } else {
                    return
                }
            }
        }
    }

    private static func waitForExit(
        _ completion: ProcessCompletion,
        timeout: TimeInterval
    ) async -> (status: Int32, timedOut: Bool) {
        await withTaskGroup(of: (Int32?, Bool).self) { group in
            group.addTask { (await completion.wait(), false) }
            group.addTask {
                guard timeout > 0 else { return (nil, true) }
                do {
                    try await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                    return (nil, true)
                } catch {
                    return (nil, false)
                }
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

    private static func waitForDrains(
        _ completion: PipeDrainCompletion,
        timeout: TimeInterval
    ) async -> (data: (output: Data, error: Data)?, timedOut: Bool) {
        await withTaskGroup(of: ((output: Data, error: Data)?, Bool).self) { group in
            group.addTask { (await completion.wait(), false) }
            group.addTask {
                guard timeout > 0 else { return (nil, true) }
                do {
                    try await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                    return (nil, true)
                } catch {
                    return (nil, false)
                }
            }
            while let first = await group.next() {
                if let data = first.0 {
                    group.cancelAll()
                    completion.cancelWaiter()
                    return (data, false)
                }
                if first.1 {
                    group.cancelAll()
                    completion.cancelWaiter()
                    return (nil, true)
                }
            }
            return (nil, true)
        }
    }

    private static func stop(
        _ command: SpawnedCommand,
        outputTask: Task<Void, Never>,
        errorTask: Task<Void, Never>
    ) async {
        // This path already represents timeout/cancellation. Kill the owned
        // group synchronously rather than scheduling a later bare-PID signal,
        // which could observe a reused identifier after the command exits.
        command.signalGroup(SIGKILL)
        outputTask.cancel()
        errorTask.cancel()
        _ = await outputTask.value
        _ = await errorTask.value
    }

    private static func waitForProcess(_ pid: pid_t) -> Int32 {
        var rawStatus: Int32 = 0
        while waitpid(pid, &rawStatus, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : signal
    }

    private static func timeoutError() -> NekoPilotError {
        .processFailed(CoreL10n.text("命令执行超时", "The command timed out"))
    }

    private static func posixError(_ code: Int32) -> NekoPilotError {
        .processFailed(String(cString: strerror(code)))
    }
}

/// Darwin has no atomic `pipe2(O_CLOEXEC)`. Every in-module spawn path that
/// creates descriptors must hold this gate from `pipe` through `posix_spawn`,
/// closing the window where a concurrent child could inherit a raw writer.
enum ProcessSpawnGate {
    private static let lock = NSLock()

    static func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The group is created atomically by `posix_spawn` before `exec`, avoiding
/// macOS's `setpgid`-after-exec `EACCES` race. Signals target only this owned
/// group; timeout handling does not retain a bare PID for delayed escalation.
private struct SpawnedCommand: Sendable {
    let pid: pid_t
    let outputDescriptor: Int32
    let errorDescriptor: Int32

    func signalGroup(_ signal: Int32) {
        _ = kill(-pid, signal)
    }
}

private enum PipeStream: Sendable {
    case output
    case error
}

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

private final class PipeDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var output: Data?
    private var error: Data?
    private var waiter: CheckedContinuation<(output: Data, error: Data)?, Never>?
    private var waitCancelled = false

    func finish(stream: PipeStream, data: Data) {
        lock.lock()
        switch stream {
        case .output: output = data
        case .error: error = data
        }
        let result = output.flatMap { output in error.map { (output, $0) } }
        let waiter = result == nil ? nil : self.waiter
        if waiter != nil { self.waiter = nil }
        lock.unlock()
        if let result { waiter?.resume(returning: result) }
    }

    func wait() async -> (output: Data, error: Data)? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let output, let error {
                    lock.unlock()
                    continuation.resume(returning: (output, error))
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
