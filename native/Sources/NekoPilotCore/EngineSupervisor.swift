import Darwin
import Foundation

public actor EngineSupervisor {
    private let settings: SettingsStore
    private let compiler: ConfigurationCompiler
    private let systemProxy: SystemProxyManager
    private let nativeAPI: NativeControlClient
    private let ownershipURL: URL?
    private let configurationValidator: @Sendable (URL) async throws -> Void
    private let logger: any AppLogging
    private var status: EngineStatus = .stopped
    private var process: Process?
    private var sessionID: UUID?
    private var apiEndpoint: LocalAPIEndpoint?
    private var healthProbePort: Int?
    private var proxySessionID: UUID?
    private let selectorControlGate = AsyncSerialGate()
    private var epoch: UInt64 = 0
    private var configurationGeneration: UInt64 = 0
    private var isShuttingDown = false
    private var statusContinuations: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]

    public init(
        settings: SettingsStore,
        compiler: ConfigurationCompiler,
        systemProxy: SystemProxyManager,
        nativeAPI: NativeControlClient,
        ownershipURL: URL? = nil,
        logger: any AppLogging = AppLogger.shared,
        configurationValidator: @escaping @Sendable (URL) async throws -> Void = {
            try await SingBoxValidator.validate(configuration: $0)
        }
    ) {
        self.settings = settings
        self.compiler = compiler
        self.systemProxy = systemProxy
        self.nativeAPI = nativeAPI
        self.ownershipURL = ownershipURL
        self.logger = logger
        self.configurationValidator = configurationValidator
    }

    public func currentStatus() -> EngineStatus { status }
    public func currentHealthProbePort() -> Int? { status.isRunning ? healthProbePort : nil }

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
        guard let ownershipURL else {
            await compiler.removeAbandonedRuntimeCandidates()
            return
        }
        do {
            if let marker = try readOwnership(at: ownershipURL) {
                if let owner = marker.ownerProcess, ProcessIdentity.matches(owner) {
                    logger.info("sing-box belongs to live NekoPilot pid=\(owner.pid); preserving")
                    return
                }
                if ProcessIdentity.matches(marker.childProcess) {
                    logger.warning("recovering orphan sing-box pid=\(marker.childProcess.pid)")
                    terminateProcessGroup(pid: marker.childProcess.pid)
                    guard await waitUntilDead(marker.childProcess, attempts: 25) else {
                        throw EngineFailure(
                            kind: .shutdown,
                            message: CoreL10n.text(
                                "无法清理遗留的 sing-box 进程",
                                "Could not terminate the orphaned sing-box process"
                            )
                        )
                    }
                }
                try removeOwnershipMarker(at: ownershipURL)
            }
        } catch {
            logger.error("orphan sing-box recovery failed: \(error.localizedDescription)")
        }
        await compiler.removeAbandonedRuntimeCandidates()
    }

    public func recoverSystemProxy() async {
        do {
            try await systemProxy.recoverStaleOwnership()
        } catch {
            logger.warning("deferred stale system proxy recovery: \(error.localizedDescription)")
        }
    }

    public func start(selectedNode: String?) async throws {
        guard !isShuttingDown, !status.isBusy, !status.isRunning else { return }
        epoch &+= 1
        let startEpoch = epoch
        let startConfigurationGeneration = beginConfigurationOperation()
        var startedSession: UUID?
        var appliedProxySession: UUID?
        setStatus(.starting)
        do {
            let runtimeSettings = await settings.runtimeConfiguration()
            let mixedPort = runtimeSettings.proxyPort
            let apiEndpoint = try LocalAPIEndpoint.make()
            let healthProbePort = try makeHealthProbePort(excluding: [mixedPort, apiEndpoint.port])
            await nativeAPI.configure(endpoint: apiEndpoint)
            let candidate = try await compiler.makeRuntimeConfigurationCandidate(
                selectedNode: selectedNode,
                apiEndpoint: apiEndpoint,
                healthProbePort: healthProbePort,
                runtimeSettings: runtimeSettings
            )
            defer { candidate.discard() }
            try await validateConfigurationCandidate(candidate.configurationURL)
            try ensureCurrent(startEpoch)
            try ensureConfigurationCurrent(startConfigurationGeneration)
            // Promotion is synchronous and atomic, so no other actor message
            // can replace the validated bytes between this commit and spawn.
            let config = try candidate.commit()

            for port in [mixedPort, apiEndpoint.port, healthProbePort] where PortProbe.isListening(port) {
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
            self.apiEndpoint = apiEndpoint
            self.healthProbePort = healthProbePort

            guard await waitUntilReady(endpoint: apiEndpoint, epoch: startEpoch) else {
                try ensureCurrent(startEpoch)
                throw EngineFailure(
                    kind: .startup,
                    message: CoreL10n.text("sing-box 启动超时", "sing-box startup timed out")
                )
            }
            try ensureCurrent(startEpoch)
            guard child.isRunning else {
                throw EngineFailure(
                    kind: .startup,
                    message: CoreL10n.text(
                        "sing-box 启动后意外退出",
                        "sing-box exited unexpectedly during startup"
                    )
                )
            }

            if !runtimeSettings.skipSystemProxy {
                let proxySession = try await systemProxy.apply(port: mixedPort)
                appliedProxySession = proxySession
                proxySessionID = proxySession
            }
            try ensureCurrent(startEpoch)
            if let selectedNode { try await nativeAPI.select(node: selectedNode) }
            try ensureCurrent(startEpoch)
            setStatus(.running)
            logger.info("sing-box running pid=\(child.processIdentifier) session=\(session)")
        } catch is CancellationError {
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            await nativeAPI.disconnect()
            if let appliedProxySession {
                try? await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
            }
            if epoch == startEpoch { setStatus(.stopped) }
            throw CancellationError()
        } catch {
            logger.error("engine start failed: \(error.localizedDescription)")
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            if let appliedProxySession {
                try? await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
            }
            await nativeAPI.disconnect()
            if epoch == startEpoch {
                setStatus(.failed(failure(from: error, fallback: .startup)))
            }
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
        await nativeAPI.disconnect()
        var proxyCleanupError: Error?
        do {
            try await systemProxy.removeOwnedProxy(expectedSession: stoppingProxySession)
            if proxySessionID == stoppingProxySession { proxySessionID = nil }
        } catch {
            proxyCleanupError = error
            logger.error("system proxy cleanup failed during stop: \(error.localizedDescription)")
        }
        guard epoch == stopEpoch else { return }
        if !didStop {
            setStatus(.failed(EngineFailure(
                kind: .shutdown,
                message: CoreL10n.text("sing-box 无法停止", "sing-box could not be stopped")
            )))
        } else if let proxyCleanupError {
            setStatus(.failed(EngineFailure(
                kind: .systemProxy,
                message: CoreL10n.text(
                    "系统代理恢复失败：\(proxyCleanupError.localizedDescription)",
                    "System proxy restoration failed: \(proxyCleanupError.localizedDescription)"
                )
            )))
        } else {
            setStatus(.stopped)
        }
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
            logger.error("lifecycle restart failed: \(error.localizedDescription)")
        }
    }

    public func reload(selectedNode: String?) async throws {
        guard status.isRunning else {
            try await prepareConfiguration(selectedNode: selectedNode)
            return
        }

        var reloadEpoch: UInt64?
        var reloadConfigurationGeneration: UInt64?
        var didCommitCandidate = false
        // Acquire before compilation so FIFO order reflects caller intent,
        // not whichever validator happens to finish first. Manual selections
        // submitted after this reload will therefore apply after it.
        try await selectorControlGate.acquire()
        do {
            // Cancellation while queued must not produce a candidate, supersede
            // another reload, commit configuration, or signal sing-box.
            try Task.checkCancellation()
            // A preceding reload may have recovered the process while this
            // request was queued. Capture the current session only after the
            // gate is owned; never signal or poll a stale Process snapshot.
            guard status.isRunning,
                  let child = process,
                  let runningSession = sessionID,
                  child.isRunning else {
                throw CancellationError()
            }
            let currentEpoch = epoch
            reloadEpoch = currentEpoch
            let configurationGeneration = beginConfigurationOperation()
            reloadConfigurationGeneration = configurationGeneration
            guard let apiEndpoint else {
                throw EngineFailure(
                    kind: .control,
                    message: CoreL10n.text(
                        "sing-box API 会话已丢失",
                        "The sing-box API session was lost"
                    )
                )
            }
            let candidate = try await compiler.makeRuntimeConfigurationCandidate(
                selectedNode: selectedNode,
                apiEndpoint: apiEndpoint,
                healthProbePort: healthProbePort
            )
            defer { candidate.discard() }
            try await validateConfigurationCandidate(candidate.configurationURL)
            try ensureCurrent(currentEpoch)
            // A newer request owns the eventual live file. Supersession is an
            // observable cancellation, not success: the newer request may
            // still fail validation without committing either candidate.
            try ensureConfigurationCurrent(configurationGeneration)
            let expectedNodes = try expectedSelectorNodes(in: candidate.configurationURL)
            _ = try candidate.commit()
            didCommitCandidate = true
            // The standard sing-box executable reloads atomically on SIGHUP,
            // preserving native rule-set refresh.
            guard kill(child.processIdentifier, SIGHUP) == 0 else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "无法请求 sing-box 重新加载",
                        "Could not request a sing-box reload"
                    )
                )
            }
            try await confirmReloadWhileHoldingGate(
                child: child,
                runningSession: runningSession,
                expectedNodes: expectedNodes,
                selectedNode: selectedNode,
                epoch: currentEpoch,
                configurationGeneration: configurationGeneration
            )
            await selectorControlGate.release()
        } catch {
            // A stale request must never publish its own failure after a newer
            // lifecycle operation has taken ownership. Check while the gate is
            // still held so a queued reload cannot change generation first.
            do {
                if let reloadEpoch { try ensureCurrent(reloadEpoch) }
                if let reloadConfigurationGeneration {
                    try ensureConfigurationCurrent(reloadConfigurationGeneration)
                }
            } catch {
                await selectorControlGate.release()
                throw error
            }

            if didCommitCandidate {
                let reloadFailure = Self.classifyReloadFailure(
                    error,
                    candidateWasCommitted: true
                )
                logger.warning(
                    "reload result became ambiguous after commit; recovering before releasing control: "
                        + error.localizedDescription
                )
                do {
                    // Recovery remains inside the same FIFO transaction. A
                    // following reload cannot validate against or signal the
                    // ambiguous process, and will capture the recovered
                    // session only after this completes.
                    try await recoverCommittedReload(selectedNode: selectedNode)
                    await selectorControlGate.release()
                    return
                } catch {
                    await selectorControlGate.release()
                    if isShuttingDown || error is CancellationError {
                        throw CancellationError()
                    }
                    throw reloadFailure
                }
            }

            await selectorControlGate.release()
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? EngineFailure { throw failure }
            throw Self.classifyReloadFailure(error, candidateWasCommitted: false)
        }
    }

    private func recoverCommittedReload(selectedNode: String?) async throws {
        // Use a fresh task so cancellation of the user operation after commit
        // cannot interrupt restoration halfway through. Application shutdown
        // is still authoritative through `isShuttingDown`.
        let recovery = Task { [self] in
            await stop()
            guard !isShuttingDown else { throw CancellationError() }
            try await start(selectedNode: selectedNode)
            guard status.isRunning else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "sing-box 重新加载恢复失败",
                        "Could not recover from the sing-box reload"
                    )
                )
            }
        }
        try await recovery.value
    }

    nonisolated static func classifyReloadFailure(
        _ error: Error,
        candidateWasCommitted: Bool
    ) -> Error {
        // Before commit, preserve validation/compiler/control errors so
        // callers keep the working process. After commit, an untyped control
        // error leaves the observed reload result ambiguous and must use the
        // typed recovery path.
        guard candidateWasCommitted else { return error }
        return EngineFailure(kind: .reload, message: error.localizedDescription)
    }

    private func confirmReloadWhileHoldingGate(
        child: Process,
        runningSession: UUID,
        expectedNodes: Set<String>,
        selectedNode: String?,
        epoch expectedEpoch: UInt64,
        configurationGeneration expectedGeneration: UInt64
    ) async throws {
        for _ in 0 ..< 50 {
            try ensureCurrent(expectedEpoch)
            try ensureConfigurationCurrent(expectedGeneration)
            guard sessionID == runningSession, child.isRunning else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "sing-box 在重新加载时退出",
                        "sing-box exited while reloading"
                    )
                )
            }
            if let selector = try? await nativeAPI.selector(knownNodes: Array(expectedNodes)) {
                try ensureCurrent(expectedEpoch)
                try ensureConfigurationCurrent(expectedGeneration)
                guard Set(selector.nodes) == expectedNodes else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if let selectedNode, selector.current != selectedNode {
                    try await nativeAPI.select(node: selectedNode)
                    // `select` crosses an actor boundary. A newer reload may
                    // have started while it was in flight, so never report the
                    // old mutation as current after the await.
                    try ensureCurrent(expectedEpoch)
                    try ensureConfigurationCurrent(expectedGeneration)
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw EngineFailure(
            kind: .reload,
            message: CoreL10n.text(
                "规则重新加载未生效",
                "The routing rule reload did not take effect"
            )
        )
    }

    public func select(node: String) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        switch status {
        case .running:
            try await selectorControlGate.acquire()
            do {
                try Task.checkCancellation()
                guard !isShuttingDown, status.isRunning else { throw CancellationError() }
                try await nativeAPI.select(node: node)
                await selectorControlGate.release()
            } catch {
                await selectorControlGate.release()
                throw error
            }
        case .stopped, .failed:
            try await prepareConfiguration(selectedNode: node)
        case .starting, .stopping:
            // A selector request must never rewrite the shared runtime
            // configuration while start/stop is still consuming it. The UI
            // also blocks these taps; this guard keeps non-UI callers safe.
            throw CancellationError()
        }
    }

    /// Validates and promotes a configuration while the core is stopped.
    /// UI and service callers should use this entry point instead of writing
    /// the shared live configuration through `ConfigurationCompiler`.
    public func prepareConfiguration(selectedNode: String?) async throws {
        guard !isShuttingDown, !status.isBusy, !status.isRunning else {
            throw CancellationError()
        }
        let preparationEpoch = epoch
        let preparationGeneration = beginConfigurationOperation()
        do {
            let candidate = try await compiler.makeRuntimeConfigurationCandidate(selectedNode: selectedNode)
            defer { candidate.discard() }
            try await validateConfigurationCandidate(candidate.configurationURL)
            try ensureCurrent(preparationEpoch)
            try ensureConfigurationCurrent(preparationGeneration)
            _ = try candidate.commit()
        } catch {
            // Validation may finish with an error only after a newer request
            // has already committed. Supersession takes precedence over that
            // stale error so callers cannot roll back newer persisted intent.
            try ensureCurrent(preparationEpoch)
            try ensureConfigurationCurrent(preparationGeneration)
            throw error
        }
    }

    private func validateConfigurationCandidate(_ url: URL) async throws {
        do {
            try await configurationValidator(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as EngineFailure {
            throw failure
        } catch let NekoPilotError.processFailed(message) {
            // SingBoxValidator historically reports a non-zero `check` exit
            // through the source-compatible string error. At this boundary it
            // specifically means that sing-box rejected the candidate.
            throw EngineFailure(kind: .configuration, message: message)
        } catch let error as NekoPilotError {
            // Preserve actionable infrastructure errors such as a missing
            // bundled core rather than disguising them as invalid JSON.
            throw error
        } catch {
            throw EngineFailure(
                kind: .configuration,
                message: error.localizedDescription
            )
        }
    }

    private func failure(from error: Error, fallback: EngineFailure.Kind) -> EngineFailure {
        if let failure = error as? EngineFailure { return failure }
        return EngineFailure(kind: fallback, message: error.localizedDescription)
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
        logger.info("shutdown: terminating sing-box child")
        let didStop = await stopProcessOnly(expectedSession: stoppingSession)
        await nativeAPI.disconnect()
        logger.info("shutdown: sing-box child terminated=\(didStop)")
        do {
            logger.info("shutdown: restoring system proxy")
            try await systemProxy.removeOwnedProxy(expectedSession: stoppingProxySession)
            if proxySessionID == stoppingProxySession { proxySessionID = nil }
            logger.info("shutdown: system proxy restored")
        } catch {
            logger.error("system proxy cleanup failed during shutdown: \(error.localizedDescription)")
        }
        setStatus(didStop ? .stopped : .failed(EngineFailure(
            kind: .shutdown,
            message: CoreL10n.text(
                "sing-box 无法停止",
                "sing-box could not be stopped"
            )
        )))
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
        let logger = logger
        child.executableURL = executable
        child.arguments = ["run", "-c", config.path, "--disable-color"]
        child.currentDirectoryURL = config.deletingLastPathComponent()
        child.standardOutput = standardOutput
        child.standardError = standardError
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logger.info("[sing-box] \(String(decoding: data, as: UTF8.self))")
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = "[sing-box] \(String(decoding: data, as: UTF8.self))"
            if message.contains(" ERROR ") {
                logger.error(message)
            } else {
                logger.warning(message)
            }
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

    private func waitUntilReady(endpoint: LocalAPIEndpoint, epoch expectedEpoch: UInt64) async -> Bool {
        for _ in 0 ..< 100 {
            guard expectedEpoch == epoch, !isShuttingDown, process?.isRunning == true else { return false }
            // The API status endpoint is stream-oriented and can delay its
            // first status event long after sing-box has accepted loopback
            // control connections. The bound local port is the correct
            // readiness gate for starting system proxy ownership.
            if PortProbe.isListening(endpoint.port) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func makeHealthProbePort(excluding excludedPorts: Set<Int>) throws -> Int {
        for _ in 0 ..< 8 {
            let candidate = try LocalAPIEndpoint.make().port
            if !excludedPorts.contains(candidate), !PortProbe.isListening(candidate) {
                return candidate
            }
        }
        throw EngineFailure(
            kind: .startup,
            message: CoreL10n.text(
                "无法分配节点健康检查端口",
                "Could not allocate the node health-check port"
            )
        )
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
            logger.error("sing-box remained alive after SIGKILL pid=\(pid)")
            return false
        }
        process = nil
        sessionID = nil
        apiEndpoint = nil
        healthProbePort = nil
        removeOwnershipIfMatching(session: expectedSession)
        return true
    }

    private func processTerminated(session: UUID, statusCode: Int32) async {
        guard sessionID == session else { return }
        let expectedProxySession = proxySessionID
        process = nil
        sessionID = nil
        apiEndpoint = nil
        healthProbePort = nil
        removeOwnershipIfMatching(session: session)
        try? await systemProxy.removeOwnedProxy(expectedSession: expectedProxySession)
        guard sessionID == nil else { return }
        if proxySessionID == expectedProxySession { proxySessionID = nil }
        if status == .stopping || isShuttingDown {
            setStatus(.stopped)
        } else {
            let message = CoreL10n.text(
                "sing-box 已退出（状态码 \(statusCode)）",
                "sing-box exited with status \(statusCode)"
            )
            logger.error(message)
            setStatus(.failed(EngineFailure(kind: .unexpectedExit, message: message)))
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

    private func beginConfigurationOperation() -> UInt64 {
        configurationGeneration &+= 1
        return configurationGeneration
    }

    private func ensureConfigurationCurrent(_ expectedGeneration: UInt64) throws {
        guard expectedGeneration == configurationGeneration else { throw CancellationError() }
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
            throw EngineFailure(
                kind: .startup,
                message: CoreL10n.text(
                    "无法确认 sing-box 进程身份",
                    "Could not verify the sing-box process identity"
                )
            )
        }
        let marker = EngineOwnershipMarker(
            sessionID: session.uuidString,
            ownerProcess: ProcessIdentity.current(),
            childProcess: childIdentity,
            configPath: config.path,
            mixedPort: mixedPort,
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
            logger.warning("failed to remove sing-box ownership marker: \(error.localizedDescription)")
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
