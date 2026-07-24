import Darwin
import Foundation

public actor EngineSupervisor {
    private let settings: SettingsStore
    private let compiler: ConfigurationCompiler
    private let systemProxy: SystemProxyManager
    private let nativeAPI: NativeControlClient
    private let ownershipURL: URL?
    private let configurationValidator: @Sendable (URL) async throws -> Void
    private let reloadHealthProbe: @Sendable (Int) async -> Bool
    private let logger: any AppLogging
    private var status: EngineStatus = .stopped
    private var process: Process?
    private var sessionID: UUID?
    private var apiEndpoint: LocalAPIEndpoint?
    private var healthProbePort: Int?
    private var mixedPort: Int?
    private var proxySessionID: UUID?
    private var activeReloadCandidate: RuntimeConfigurationCandidate?
    private var reloadTransition: ReloadTransition?
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
        },
        reloadHealthProbe: (@Sendable (Int) async -> Bool)? = nil
    ) {
        self.settings = settings
        self.compiler = compiler
        self.systemProxy = systemProxy
        self.nativeAPI = nativeAPI
        self.ownershipURL = ownershipURL
        self.logger = logger
        self.configurationValidator = configurationValidator
        self.reloadHealthProbe = reloadHealthProbe ?? { port in
            if case .reachable = await ProxyHealthProbe().check(port: port) {
                return true
            }
            return false
        }
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
            self.mixedPort = mixedPort

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

            guard await reloadHealthProbe(healthProbePort) else {
                throw EngineFailure(
                    kind: .startup,
                    message: CoreL10n.text(
                        "sing-box 启动后无法通过当前节点访问网络",
                        "sing-box started but could not reach the network through the selected node"
                    )
                )
            }
            try ensureCurrent(startEpoch)

            if !runtimeSettings.skipSystemProxy {
                do {
                    let proxySession = try await systemProxy.apply(port: mixedPort)
                    appliedProxySession = proxySession
                    proxySessionID = proxySession
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw systemProxyFailure(error)
                }
            }
            try ensureCurrent(startEpoch)
            if let selectedNode { try await nativeAPI.select(node: selectedNode) }
            try ensureCurrent(startEpoch)
            setStatus(.running)
            logger.info("sing-box running pid=\(child.processIdentifier) session=\(session)")
        } catch is CancellationError {
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            await nativeAPI.disconnect()
            var proxyCleanupError: Error?
            if let appliedProxySession {
                do {
                    try await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
                } catch {
                    proxyCleanupError = error
                    logger.error("system proxy cleanup failed after cancelled start: \(error.localizedDescription)")
                }
            }
            if let proxyCleanupError {
                let failure = systemProxyFailure(proxyCleanupError)
                if epoch == startEpoch { setStatus(.failed(failure)) }
                throw failure
            }
            if epoch == startEpoch { setStatus(.stopped) }
            throw CancellationError()
        } catch {
            logger.error("engine start failed: \(error.localizedDescription)")
            if let startedSession { _ = await stopProcessOnly(expectedSession: startedSession) }
            var proxyCleanupError: Error?
            if let appliedProxySession {
                do {
                    try await systemProxy.removeOwnedProxy(expectedSession: appliedProxySession)
                } catch {
                    proxyCleanupError = error
                    logger.error("system proxy cleanup failed after failed start: \(error.localizedDescription)")
                }
            }
            await nativeAPI.disconnect()
            if epoch == startEpoch {
                setStatus(.failed(failure(from: proxyCleanupError ?? error, fallback: .startup)))
            }
            if let proxyCleanupError {
                throw systemProxyFailure(proxyCleanupError)
            }
            throw error
        }
    }

    public func stop() async {
        guard status != .stopped else { return }
        guard (try? await selectorControlGate.acquire()) != nil else { return }
        guard status != .stopped else {
            await selectorControlGate.release()
            return
        }
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
        guard epoch == stopEpoch else {
            await selectorControlGate.release()
            return
        }
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
        await selectorControlGate.release()
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
        var preflightRuntime: ReloadPreflightRuntime?
        // Acquire before compilation so FIFO order reflects caller intent,
        // not whichever validator happens to finish first. Manual selections
        // submitted after this reload will therefore apply after it.
        try await selectorControlGate.acquire()
        do {
            // Cancellation while queued must not produce a candidate, supersede
            // another reload, promote configuration, or hand off the live
            // proxy.
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
            guard let liveMixedPort = mixedPort else {
                throw EngineFailure(
                    kind: .control,
                    message: CoreL10n.text(
                        "sing-box 代理监听端口已丢失",
                        "The live sing-box proxy listener was lost"
                    )
                )
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
            try await ReloadSafetyPipeline.prepare(
                preflight: {
                    preflightRuntime = try await self.preflightReloadCandidate(
                        sourceConfigurationURL: candidate.configurationURL,
                        selectedNode: selectedNode,
                        expectedNodes: expectedNodes,
                        liveMixedPort: liveMixedPort,
                        epoch: currentEpoch,
                        configurationGeneration: configurationGeneration
                    )
                    try Task.checkCancellation()
                    try self.ensureCurrent(currentEpoch)
                    try self.ensureConfigurationCurrent(configurationGeneration)
                },
                commit: {
                    guard let preflightRuntime else {
                        throw EngineFailure(
                            kind: .reload,
                            message: CoreL10n.text(
                                "候选 sing-box 未建立",
                                "The candidate sing-box was not prepared"
                            )
                        )
                    }
                    // Promote the exact bytes that were started and proved
                    // healthy. The source candidate is only the immutable
                    // input used to build this isolated preflight runtime.
                    _ = try preflightRuntime.candidate.promote()
                }
            )
            didCommitCandidate = true
            guard let runtime = preflightRuntime else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "候选 sing-box 未建立",
                        "The candidate sing-box was not prepared"
                    )
                )
            }
            try await ReloadSafetyPipeline.handoff {
                try await self.adoptReloadCandidate(
                    runtime,
                    oldChild: child,
                    oldSession: runningSession,
                    epoch: currentEpoch,
                    configurationGeneration: configurationGeneration
                )
            }
            preflightRuntime = nil
            await selectorControlGate.release()
        } catch {
            // A preflight candidate is outside the live-engine state until the
            // handoff returns. Clean it up before checking whether this reload
            // became stale; otherwise cancellation/supersession could release
            // the gate while leaving a healthy-but-unadopted core running.
            if let preflightRuntime {
                await abandonReloadCandidate(preflightRuntime)
            }

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
                    "reload handoff failed after promotion; preserving the live core and proxy ownership: "
                        + error.localizedDescription
                )
                await selectorControlGate.release()
                if isShuttingDown { throw CancellationError() }
                throw reloadFailure
            }

            await selectorControlGate.release()
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? EngineFailure { throw failure }
            throw Self.classifyReloadFailure(error, candidateWasCommitted: false)
        }
    }

    nonisolated static func classifyReloadFailure(
        _ error: Error,
        candidateWasCommitted: Bool
    ) -> Error {
        // Before commit, preserve validation/compiler/control errors so
        // callers keep the working process. After commit, an untyped control
        // error means durable configuration changed while the old core stayed
        // active; callers must use the typed recovery path.
        guard candidateWasCommitted else { return error }
        return EngineFailure(kind: .reloadCommitted, message: error.localizedDescription)
    }

    private func preflightReloadCandidate(
        sourceConfigurationURL: URL,
        selectedNode: String?,
        expectedNodes: Set<String>,
        liveMixedPort: Int,
        epoch expectedEpoch: UInt64,
        configurationGeneration expectedGeneration: UInt64
    ) async throws -> ReloadPreflightRuntime {
        let candidateAPI = try makeUniqueAPIEndpoint(excluding: [liveMixedPort])
        let candidateMixedPort = try makeAvailablePort(excluding: [liveMixedPort, candidateAPI.port])
        let candidateHealthPort = try makeAvailablePort(
            excluding: [liveMixedPort, candidateAPI.port, candidateMixedPort]
        )
        let candidate = try await compiler.makeReloadPreflightCandidate(
            from: sourceConfigurationURL,
            apiEndpoint: candidateAPI,
            healthProbePort: candidateHealthPort,
            proxyPort: candidateMixedPort
        )
        var candidateProcess: Process?
        var candidateClient: NativeControlClient?
        let candidateSession = UUID()
        let executable: URL
        do {
            try await validateConfigurationCandidate(candidate.configurationURL)
            try ensureCurrent(expectedEpoch)
            try ensureConfigurationCurrent(expectedGeneration)

            executable = try SingBoxLocator.executable()
            let child = try spawnPreflight(
                executable: executable,
                config: candidate.configurationURL,
                session: candidateSession
            )
            candidateProcess = child
            let client = NativeControlClient(endpoint: candidateAPI, logger: logger)
            candidateClient = client

            guard await waitUntilPreflightReady(
                process: child,
                client: client,
                apiEndpoint: candidateAPI,
                expectedNodes: expectedNodes,
                selectedNode: selectedNode,
                epoch: expectedEpoch,
                configurationGeneration: expectedGeneration
            ) else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "候选 sing-box 未通过启动健康检查",
                        "The candidate sing-box failed its startup health check"
                    )
                )
            }

            let isHealthy = await reloadHealthProbe(candidateHealthPort)
            try ensureCurrent(expectedEpoch)
            try ensureConfigurationCurrent(expectedGeneration)
            guard isHealthy, child.isRunning else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "候选 sing-box 无法通过所选节点访问网络",
                        "The candidate sing-box could not reach the network through the selected node"
                    )
                )
            }
        } catch {
            if let candidateClient { await candidateClient.disconnect() }
            var cleanupError: Error?
            if let candidateProcess {
                do {
                    try await stopPreflightProcess(candidateProcess)
                } catch {
                    cleanupError = error
                }
            }
            candidate.discard()
            if let cleanupError { throw cleanupError }
            throw error
        }
        guard let candidateProcess, let candidateClient else {
            candidate.discard()
            throw EngineFailure(
                kind: .reload,
                message: CoreL10n.text(
                    "候选 sing-box 进程未建立",
                    "The candidate sing-box process was not created"
                )
            )
        }
        return ReloadPreflightRuntime(
            candidate: candidate,
            process: candidateProcess,
            client: candidateClient,
            executable: executable,
            session: candidateSession,
            apiEndpoint: candidateAPI,
            mixedPort: candidateMixedPort,
            healthProbePort: candidateHealthPort
        )
    }

    private func adoptReloadCandidate(
        _ candidate: ReloadPreflightRuntime,
        oldChild: Process,
        oldSession: UUID,
        epoch expectedEpoch: UInt64,
        configurationGeneration expectedGeneration: UInt64
    ) async throws {
        try ensureCurrent(expectedEpoch)
        try ensureConfigurationCurrent(expectedGeneration)
        guard sessionID == oldSession, process === oldChild else {
            throw CancellationError()
        }
        guard candidate.process.isRunning else {
            throw EngineFailure(
                kind: .reload,
                message: CoreL10n.text(
                    "候选 sing-box 在切换前退出",
                    "The candidate sing-box exited before handoff"
                )
            )
        }

        let oldMixedPort = mixedPort
        let oldProxySession = proxySessionID
        reloadTransition = ReloadTransition(
            oldSession: oldSession,
            candidateSession: candidate.session
        )
        var proxyWasHandedOff = false
        do {
            if let oldProxySession {
                guard oldMixedPort != nil else {
                    throw EngineFailure(
                        kind: .systemProxy,
                        message: CoreL10n.text(
                            "旧 core 的代理监听端口已丢失",
                            "The old core's proxy listener was lost"
                        )
                    )
                }
                // This keeps the system proxy enabled and owned. It changes
                // only the destination port after the candidate passed its
                // end-to-end health check.
                try await systemProxy.handoff(
                    expectedSession: oldProxySession,
                    toPort: candidate.mixedPort
                )
                proxyWasHandedOff = true
                // Keep the old port for rollback until the new process is the
                // active session. Do not insert a cancellation check here:
                // once proxy ownership moved, the handoff must finish.
            }

            guard candidate.process.isRunning else {
                throw EngineFailure(
                    kind: .reload,
                    message: CoreL10n.text(
                        "候选 sing-box 在代理切换后退出",
                        "The candidate sing-box exited during handoff"
                    )
                )
            }

            try writeOwnership(
                child: candidate.process,
                executable: candidate.executable,
                config: candidate.candidate.configurationURL,
                session: candidate.session,
                mixedPort: candidate.mixedPort
            )
            await nativeAPI.configure(endpoint: candidate.apiEndpoint)

            // From this point on the candidate owns the live session. The
            // old termination callback sees a different session and cannot
            // release the system proxy belonging to the new core.
            process = candidate.process
            sessionID = candidate.session
            apiEndpoint = candidate.apiEndpoint
            healthProbePort = candidate.healthProbePort
            mixedPort = candidate.mixedPort
            activeReloadCandidate = candidate.candidate
            await candidate.client.disconnect()

            // Stop only the old instance; stopProcessOnly intentionally acts
            // on the current session, which is now the candidate.
            guard await stopProcessInstance(oldChild) else {
                reloadTransition = nil
                logger.error(
                    "old sing-box remained alive after successful reload handoff pid=\(oldChild.processIdentifier)"
                )
                return
            }
            // Keep termination callbacks fenced until the old child has been
            // reaped. Neither side of the dual-core window may release the
            // still-owned system proxy while this handoff is finishing.
            reloadTransition = nil
            logger.info(
                "sing-box reload handed off old session=\(oldSession) to new session=\(candidate.session)"
            )
        } catch {
            reloadTransition = nil
            var rollbackError: Error?
            if proxyWasHandedOff,
               let oldProxySession,
               let oldMixedPort {
                do {
                    // Roll back to the old live listener, never to the
                    // user's pre-NekoPilot settings and never via release.
                    try await systemProxy.handoff(
                        expectedSession: oldProxySession,
                        toPort: oldMixedPort
                    )
                } catch {
                    rollbackError = error
                    logger.error(
                        "system proxy handoff rollback failed: \(error.localizedDescription)"
                    )
                }
            }
            if let rollbackError {
                throw systemProxyFailure(rollbackError)
            }
            throw error
        }
    }

    private func abandonReloadCandidate(_ candidate: ReloadPreflightRuntime) async {
        await candidate.client.disconnect()
        do {
            try await stopPreflightProcess(candidate.process)
        } catch {
            logger.error(
                "candidate sing-box cleanup failed: \(error.localizedDescription)"
            )
        }
        candidate.candidate.discard()
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

    private func systemProxyFailure(_ error: Error) -> EngineFailure {
        if let failure = error as? EngineFailure, failure.kind == .systemProxy {
            return failure
        }
        return EngineFailure(
            kind: .systemProxy,
            message: CoreL10n.text(
                "系统代理操作失败：\(error.localizedDescription)",
                "System proxy operation failed: \(error.localizedDescription)"
            )
        )
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
        do {
            try await selectorControlGate.acquire()
        } catch {
            setStatus(.failed(EngineFailure(
                kind: .shutdown,
                message: CoreL10n.text(
                    "关闭时无法获得引擎控制权",
                    "Could not acquire engine control during shutdown"
                )
            )))
            return
        }
        let stoppingSession = sessionID
        let stoppingProxySession = proxySessionID
        setStatus(.stopping)
        logger.info("shutdown: terminating sing-box child")
        let didStop = await stopProcessOnly(expectedSession: stoppingSession)
        await nativeAPI.disconnect()
        logger.info("shutdown: sing-box child terminated=\(didStop)")
        var proxyCleanupError: Error?
        do {
            logger.info("shutdown: restoring system proxy")
            try await systemProxy.removeOwnedProxy(expectedSession: stoppingProxySession)
            if proxySessionID == stoppingProxySession { proxySessionID = nil }
            logger.info("shutdown: system proxy restored")
        } catch {
            proxyCleanupError = error
            logger.error("system proxy cleanup failed during shutdown: \(error.localizedDescription)")
        }
        if !didStop {
            setStatus(.failed(EngineFailure(
                kind: .shutdown,
                message: CoreL10n.text(
                    "sing-box 无法停止",
                    "sing-box could not be stopped"
                )
            )))
        } else if let proxyCleanupError {
            setStatus(.failed(systemProxyFailure(proxyCleanupError)))
        } else {
            setStatus(.stopped)
        }
        await selectorControlGate.release()
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

    private func spawnPreflight(
        executable: URL,
        config: URL,
        session: UUID
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
            logger.info("[sing-box preflight] \(String(decoding: data, as: UTF8.self))")
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logger.warning("[sing-box preflight] \(String(decoding: data, as: UTF8.self))")
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
        return child
    }

    private func stopPreflightProcess(_ child: Process) async throws {
        let stopped = await stopProcessInstance(child)
        guard stopped else {
            throw EngineFailure(
                kind: .reload,
                message: CoreL10n.text(
                    "无法停止候选 sing-box 进程",
                    "Could not stop the candidate sing-box process"
                )
            )
        }
    }

    private func stopProcessInstance(_ child: Process) async -> Bool {
        // Cleanup must finish even if the user operation was cancelled after
        // the health probe passed. An unstructured task starts uncancelled, so
        // its bounded TERM/KILL waits cannot collapse into a busy loop.
        let stopped = await Task.detached { () -> Bool in
            guard child.isRunning else { return true }
            terminateProcessGroup(pid: child.processIdentifier)
            for _ in 0 ..< 20 where child.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning {
                terminateProcessGroup(pid: child.processIdentifier, force: true)
                for _ in 0 ..< 20 where child.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            return !child.isRunning
        }.value
        return stopped
    }

    private func waitUntilPreflightReady(
        process: Process,
        client: NativeControlClient,
        apiEndpoint: LocalAPIEndpoint,
        expectedNodes: Set<String>,
        selectedNode: String?,
        epoch expectedEpoch: UInt64,
        configurationGeneration expectedGeneration: UInt64
    ) async -> Bool {
        for _ in 0 ..< 100 {
            do {
                try ensureCurrent(expectedEpoch)
                try ensureConfigurationCurrent(expectedGeneration)
            } catch {
                return false
            }
            guard process.isRunning else { return false }
            if PortProbe.isListening(apiEndpoint.port), await client.isReady() {
                guard let selector = try? await client.selector(knownNodes: Array(expectedNodes)),
                      Set(selector.nodes) == expectedNodes else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if let selectedNode, selector.current != selectedNode {
                    do {
                        try await client.select(node: selectedNode)
                    } catch {
                        return false
                    }
                }
                return process.isRunning
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
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

    private func makeUniqueAPIEndpoint(excluding excludedPorts: Set<Int>) throws -> LocalAPIEndpoint {
        for _ in 0 ..< 8 {
            let endpoint = try LocalAPIEndpoint.make()
            if !excludedPorts.contains(endpoint.port), !PortProbe.isListening(endpoint.port) {
                return endpoint
            }
        }
        throw EngineFailure(
            kind: .reload,
            message: CoreL10n.text(
                "无法分配候选控制端口",
                "Could not allocate the candidate control port"
            )
        )
    }

    private func makeAvailablePort(excluding excludedPorts: Set<Int>) throws -> Int {
        for _ in 0 ..< 8 {
            let port = try LocalAPIEndpoint.make().port
            if !excludedPorts.contains(port), !PortProbe.isListening(port) {
                return port
            }
        }
        throw EngineFailure(
            kind: .reload,
            message: CoreL10n.text(
                "无法分配候选监听端口",
                "Could not allocate a candidate listener port"
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
        let stopped = await stopProcessInstance(child)
        guard sessionID == expectedSession else { return true }
        if !stopped || child.isRunning {
            logger.error("sing-box remained alive after SIGKILL pid=\(pid)")
            return false
        }
        process = nil
        sessionID = nil
        apiEndpoint = nil
        healthProbePort = nil
        mixedPort = nil
        activeReloadCandidate?.discard()
        activeReloadCandidate = nil
        removeOwnershipIfMatching(session: expectedSession)
        return true
    }

    private func processTerminated(session: UUID, statusCode: Int32) async {
        if let reloadTransition,
           (reloadTransition.oldSession == session || reloadTransition.candidateSession == session) {
            // During a dual-core handoff neither the old callback nor an early
            // candidate callback may release proxy ownership. The handoff
            // transaction either adopts the candidate or rolls the proxy back
            // to the old listener.
            logger.warning("ignoring sing-box termination callback during reload handoff session=\(session)")
            return
        }
        guard sessionID == session else { return }
        let expectedProxySession = proxySessionID
        process = nil
        sessionID = nil
        apiEndpoint = nil
        healthProbePort = nil
        mixedPort = nil
        activeReloadCandidate?.discard()
        activeReloadCandidate = nil
        removeOwnershipIfMatching(session: session)
        var proxyCleanupError: Error?
        do {
            try await systemProxy.removeOwnedProxy(expectedSession: expectedProxySession)
        } catch {
            proxyCleanupError = error
            logger.error("system proxy cleanup failed after sing-box exit: \(error.localizedDescription)")
        }
        guard sessionID == nil else { return }
        if proxySessionID == expectedProxySession { proxySessionID = nil }
        if let proxyCleanupError {
            setStatus(.failed(systemProxyFailure(proxyCleanupError)))
        } else if status == .stopping || isShuttingDown {
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

private struct ReloadTransition {
    let oldSession: UUID
    let candidateSession: UUID
}

private struct ReloadPreflightRuntime {
    let candidate: RuntimeConfigurationCandidate
    let process: Process
    let client: NativeControlClient
    let executable: URL
    let session: UUID
    let apiEndpoint: LocalAPIEndpoint
    let mixedPort: Int
    let healthProbePort: Int
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
