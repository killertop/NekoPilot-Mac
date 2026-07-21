import Darwin
import Foundation

public actor EngineSupervisor {
    private let settings: SettingsStore
    private let compiler: ConfigurationCompiler
    private let systemProxy: SystemProxyManager
    private let clashAPI: ClashAPIClient
    private let ownershipURL: URL?
    private var status: EngineStatus = .stopped
    private var process: Process?
    private var sessionID: UUID?
    private var proxySessionID: UUID?
    private var epoch: UInt64 = 0
    private var isShuttingDown = false
    private var statusContinuations: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]

    public init(
        settings: SettingsStore,
        compiler: ConfigurationCompiler,
        systemProxy: SystemProxyManager,
        clashAPI: ClashAPIClient,
        ownershipURL: URL? = nil
    ) {
        self.settings = settings
        self.compiler = compiler
        self.systemProxy = systemProxy
        self.clashAPI = clashAPI
        self.ownershipURL = ownershipURL
    }

    public func currentStatus() -> EngineStatus { status }

    public func states() -> AsyncStream<EngineStatus> {
        let identifier = UUID()
        return AsyncStream { continuation in
            statusContinuations[identifier] = continuation
            continuation.yield(status)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(identifier) }
            }
        }
    }

    public func recoverOwnedProcess() async {
        guard let ownershipURL else { return }
        do {
            guard let marker = try readOwnership(at: ownershipURL) else { return }
            if let owner = marker.ownerProcess, ProcessIdentity.matches(owner) {
                AppLogger.shared.info("sing-box belongs to live NekoPilot pid=\(owner.pid); preserving")
                return
            }
            if ProcessIdentity.matches(marker.childProcess) {
                AppLogger.shared.warning("recovering orphan sing-box pid=\(marker.childProcess.pid)")
                terminateProcessGroup(pid: marker.childProcess.pid)
                guard await waitUntilDead(marker.childProcess, attempts: 25) else {
                    throw NekoPilotError.processFailed("无法清理遗留的 sing-box 进程")
                }
            }
            try removeOwnershipMarker(at: ownershipURL)
        } catch {
            AppLogger.shared.error("orphan sing-box recovery failed: \(error.localizedDescription)")
        }
    }

    public func recoverSystemProxy() async {
        do {
            try await systemProxy.recoverStaleOwnership()
        } catch {
            AppLogger.shared.warning("deferred stale system proxy recovery: \(error.localizedDescription)")
        }
    }

    public func start(selectedNode: String?) async throws {
        guard !isShuttingDown, !status.isBusy, !status.isRunning else { return }
        epoch &+= 1
        let startEpoch = epoch
        var startedSession: UUID?
        var appliedProxySession: UUID?
        setStatus(.starting)
        do {
            let config = try await compiler.compile(selectedNode: selectedNode)
            try await SingBoxValidator.validate(configuration: config)
            try ensureCurrent(startEpoch)

            let mixedPort = await settings.proxyPort()
            for port in [mixedPort, SettingsStore.clashAPIPort] where PortProbe.isListening(port) {
                throw NekoPilotError.portOccupied(port)
            }
            let executable = try SingBoxLocator.executable()
            let session = UUID()
            let child = try spawn(
                executable: executable,
                config: config,
                session: session,
                mixedPort: mixedPort
            )
            startedSession = session
            process = child
            sessionID = session

            guard await waitUntilReady(epoch: startEpoch) else {
                try ensureCurrent(startEpoch)
                throw NekoPilotError.processFailed("sing-box 启动超时")
            }
            try ensureCurrent(startEpoch)
            guard child.isRunning else {
                throw NekoPilotError.processFailed("sing-box 启动后意外退出")
            }

            let skipSystemProxy = await settings.bool(SettingsStore.Key.skipSystemProxy)
            if !skipSystemProxy {
                let proxySession = try await systemProxy.apply(port: mixedPort)
                appliedProxySession = proxySession
                proxySessionID = proxySession
            }
            try ensureCurrent(startEpoch)
            if let selectedNode { try await clashAPI.select(node: selectedNode) }
            try ensureCurrent(startEpoch)
            setStatus(.running)
            AppLogger.shared.info("sing-box running pid=\(child.processIdentifier) session=\(session)")
        } catch is CancellationError {
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            if let appliedProxySession {
                try? await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
            }
            if epoch == startEpoch { setStatus(.stopped) }
            throw CancellationError()
        } catch {
            AppLogger.shared.error("engine start failed: \(error.localizedDescription)")
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            if let appliedProxySession {
                try? await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
            }
            if epoch == startEpoch { setStatus(.failed(error.localizedDescription)) }
            throw error
        }
    }

    public func stop() async {
        guard status != .stopped else { return }
        epoch &+= 1
        let stopEpoch = epoch
        let stoppingSession = sessionID
        let stoppingProxySession = proxySessionID
        setStatus(.stopping)
        // Stop the child first. Restoring every macOS network service can be
        // comparatively slow, and neither a normal disconnect nor app exit
        // may leave sing-box alive while that work is in progress.
        let didStop = await stopProcessOnly(expectedSession: stoppingSession)
        do {
            try await systemProxy.removeOwnedProxy(expectedSession: stoppingProxySession)
            if proxySessionID == stoppingProxySession { proxySessionID = nil }
        } catch {
            AppLogger.shared.error("system proxy cleanup failed during stop: \(error.localizedDescription)")
        }
        guard epoch == stopEpoch else { return }
        setStatus(didStop ? .stopped : .failed("sing-box 无法停止"))
    }

    public func restartAfterLifecycleEvent(selectedNode: String?) async {
        guard !isShuttingDown, status.isRunning else { return }
        await stop()
        guard !isShuttingDown else { return }
        do {
            try await start(selectedNode: selectedNode)
        } catch is CancellationError {
            // A newer lifecycle event or shutdown superseded this restart.
        } catch {
            AppLogger.shared.error("lifecycle restart failed: \(error.localizedDescription)")
        }
    }

    public func reload(selectedNode: String?) async throws {
        guard status.isRunning,
              let child = process,
              let runningSession = sessionID,
              child.isRunning else {
            let config = try await compiler.compile(selectedNode: selectedNode)
            try await SingBoxValidator.validate(configuration: config)
            return
        }

        // Rotate the local control secret for every reload.  Requests signed
        // with the new secret cannot be answered by the old instance, which
        // gives us a reliable hand-off boundary instead of assuming that a
        // fixed sleep was long enough for SIGHUP to take effect.
        let previousSecret = try await settings.clashSecret()
        let reloadSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await settings.set(.string(reloadSecret), for: SettingsStore.Key.clashSecret)
        var newControllerWasReady = false
        do {
            let config = try await compiler.compile(selectedNode: selectedNode)
            try await SingBoxValidator.validate(configuration: config)
            let reloadEpoch = epoch
            let expectedNodes = try expectedSelectorNodes(in: config)
            guard kill(child.processIdentifier, SIGHUP) == 0 else {
                throw NekoPilotError.processFailed("无法重新加载 sing-box 配置")
            }

            for _ in 0 ..< 50 {
                try ensureCurrent(reloadEpoch)
                guard sessionID == runningSession, child.isRunning else {
                    throw NekoPilotError.processFailed("sing-box 在重新加载时退出")
                }
                if await clashAPI.isReady() { newControllerWasReady = true }
                if let selector = try? await clashAPI.selector(),
                   Set(selector.nodes) == expectedNodes {
                    if let selectedNode, selector.current != selectedNode {
                        try await clashAPI.select(node: selectedNode)
                    }
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw NekoPilotError.processFailed("规则重新加载未生效")
        } catch {
            // If the new controller never authenticated, sing-box rejected or
            // never observed the reload and is still using the old secret.
            if !newControllerWasReady {
                try? await settings.set(.string(previousSecret), for: SettingsStore.Key.clashSecret)
            }
            throw error
        }
    }

    public func select(node: String) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if status.isRunning {
            try await clashAPI.select(node: node)
        } else {
            _ = try await compiler.compile(selectedNode: node)
        }
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        epoch &+= 1
        await stopForShutdown()
        for continuation in statusContinuations.values { continuation.finish() }
        statusContinuations.removeAll()
    }

    private func stopForShutdown() async {
        let stoppingSession = sessionID
        let stoppingProxySession = proxySessionID
        setStatus(.stopping)
        AppLogger.shared.info("shutdown: terminating sing-box child")
        let didStop = await stopProcessOnly(expectedSession: stoppingSession)
        AppLogger.shared.info("shutdown: sing-box child terminated=\(didStop)")
        do {
            AppLogger.shared.info("shutdown: restoring system proxy")
            try await systemProxy.removeOwnedProxy(expectedSession: stoppingProxySession)
            if proxySessionID == stoppingProxySession { proxySessionID = nil }
            AppLogger.shared.info("shutdown: system proxy restored")
        } catch {
            AppLogger.shared.error("system proxy cleanup failed during shutdown: \(error.localizedDescription)")
        }
        setStatus(didStop ? .stopped : .failed("sing-box 无法停止"))
    }

    private func spawn(
        executable: URL,
        config: URL,
        session: UUID,
        mixedPort: Int
    ) throws -> Process {
        let child = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.executableURL = executable
        child.arguments = ["run", "-c", config.path, "--disable-color"]
        child.currentDirectoryURL = config.deletingLastPathComponent()
        child.standardOutput = standardOutput
        child.standardError = standardError
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            AppLogger.shared.info("[sing-box] \(String(decoding: data, as: UTF8.self))")
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            AppLogger.shared.warning("[sing-box] \(String(decoding: data, as: UTF8.self))")
        }
        child.terminationHandler = { process in
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            Task {
                await self.processTerminated(
                    session: session,
                    statusCode: process.terminationStatus
                )
            }
        }
        try child.run()
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
        _ = setpgid(child.processIdentifier, child.processIdentifier)
        do {
            try writeOwnership(
                child: child,
                executable: executable,
                config: config,
                session: session,
                mixedPort: mixedPort
            )
        } catch {
            terminateProcessGroup(pid: child.processIdentifier)
            throw error
        }
        return child
    }

    private func waitUntilReady(epoch expectedEpoch: UInt64) async -> Bool {
        for _ in 0 ..< 100 {
            guard expectedEpoch == epoch, !isShuttingDown, process?.isRunning == true else { return false }
            if await clashAPI.isReady() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    @discardableResult
    private func stopProcessOnly(expectedSession: UUID?) async -> Bool {
        guard let expectedSession else {
            if process == nil { return true }
            return false
        }
        guard sessionID == expectedSession, let child = process else { return true }
        let pid = child.processIdentifier
        terminateProcessGroup(pid: pid, force: false)
        for _ in 0 ..< 15 where child.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning {
            terminateProcessGroup(pid: pid, force: true)
            for _ in 0 ..< 15 where child.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard sessionID == expectedSession else { return true }
        if child.isRunning {
            AppLogger.shared.error("sing-box remained alive after SIGKILL pid=\(pid)")
            return false
        }
        process = nil
        sessionID = nil
        removeOwnershipIfMatching(session: expectedSession)
        return true
    }

    private func processTerminated(session: UUID, statusCode: Int32) async {
        guard sessionID == session else { return }
        let expectedProxySession = proxySessionID
        process = nil
        sessionID = nil
        removeOwnershipIfMatching(session: session)
        try? await systemProxy.removeOwnedProxy(expectedSession: expectedProxySession)
        guard sessionID == nil else { return }
        if proxySessionID == expectedProxySession { proxySessionID = nil }
        if status == .stopping || isShuttingDown {
            setStatus(.stopped)
        } else {
            let message = "sing-box 已退出（状态码 \(statusCode)）"
            AppLogger.shared.error(message)
            setStatus(.failed(message))
        }
    }

    private func expectedSelectorNodes(in config: URL) throws -> Set<String> {
        let object = try JSONValue.decodeObject(from: Data(contentsOf: config))
        let selector = object["outbounds"]?.arrayValue?
            .compactMap(\.objectValue)
            .first { $0["type"]?.stringValue == "selector" && $0["tag"]?.stringValue == "ExitGateway" }
        return Set(selector?["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    private func ensureCurrent(_ expectedEpoch: UInt64) throws {
        guard expectedEpoch == epoch, !isShuttingDown else { throw CancellationError() }
    }

    private func writeOwnership(
        child: Process,
        executable: URL,
        config: URL,
        session: UUID,
        mixedPort: Int
    ) throws {
        guard let ownershipURL else { return }
        guard let childIdentity = ProcessIdentity.record(
            pid: child.processIdentifier,
            expectedExecutablePath: executable.path
        ) else {
            throw NekoPilotError.processFailed("无法确认 sing-box 进程身份")
        }
        let marker = EngineOwnershipMarker(
            sessionID: session.uuidString,
            ownerProcess: ProcessIdentity.current(),
            childProcess: childIdentity,
            configPath: config.path,
            mixedPort: mixedPort,
            clashPort: SettingsStore.clashAPIPort,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(marker), to: ownershipURL)
    }

    private func removeOwnershipIfMatching(session: UUID) {
        guard let ownershipURL,
              let marker = try? readOwnership(at: ownershipURL),
              marker.sessionID == session.uuidString else { return }
        do {
            try removeOwnershipMarker(at: ownershipURL)
        } catch {
            AppLogger.shared.warning("failed to remove sing-box ownership marker: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ next: EngineStatus) {
        status = next
        for continuation in statusContinuations.values { continuation.yield(next) }
    }

    private func removeContinuation(_ identifier: UUID) {
        statusContinuations.removeValue(forKey: identifier)
    }
}

private struct EngineOwnershipMarker: Codable, Sendable {
    let sessionID: String
    let ownerProcess: ProcessIdentityRecord?
    let childProcess: ProcessIdentityRecord
    let configPath: String
    let mixedPort: Int
    let clashPort: Int
    let createdAt: Date
}

private func readOwnership(at url: URL) throws -> EngineOwnershipMarker? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(EngineOwnershipMarker.self, from: Data(contentsOf: url))
}

private func removeOwnershipMarker(at url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
}

private func terminateProcessGroup(pid: Int32, force: Bool = false) {
    guard pid > 1 else { return }
    let signal = force ? SIGKILL : SIGTERM
    // Child is placed in its own process group. Fall back to the exact PID if
    // group creation raced or was rejected by the OS.
    if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
}

private func waitUntilDead(
    _ identity: ProcessIdentityRecord,
    attempts: Int
) async -> Bool {
    for index in 0 ..< max(1, attempts) {
        if !ProcessIdentity.matches(identity) { return true }
        if index == 9 { terminateProcessGroup(pid: identity.pid, force: true) }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return !ProcessIdentity.matches(identity)
}
