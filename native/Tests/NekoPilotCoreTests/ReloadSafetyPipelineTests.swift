import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Non-destructive live reload pipeline")
struct ReloadSafetyPipelineTests {
    @Test("Failed candidate health stops before promotion and handoff")
    func failedPreflightHasNoLiveSideEffects() async {
        let events = EventRecorder()

        do {
            try await ReloadSafetyPipeline.prepare(
                preflight: {
                    events.append("preflight")
                    throw TestFailure.preflight
                },
                commit: {
                    Issue.record("Commit must not run after failed candidate health")
                }
            )
            Issue.record("Expected preflight failure")
        } catch {
            #expect(error as? TestFailure == .preflight)
        }

        #expect(events.values == ["preflight"])
    }

    @Test("Cancellation after preflight stops before commit")
    func cancellationBeforeCommitHasNoLiveSideEffects() async {
        let events = EventRecorder()
        let gate = PreflightCancellationGate()
        let operation = Task {
            try await ReloadSafetyPipeline.prepare(
                preflight: {
                    events.append("preflight")
                    await gate.pause()
                },
                commit: {
                    events.append("commit")
                }
            )
        }

        await gate.waitUntilPaused()
        operation.cancel()
        await gate.resume()
        do {
            try await operation.value
            Issue.record("Expected cancellation before commit")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(events.values == ["preflight"])
    }

    @Test("Failed handoff has no stop start or proxy release stage")
    func failedHandoffPreservesLiveRuntime() async {
        let events = EventRecorder()

        do {
            try await ReloadSafetyPipeline.handoff {
                events.append("handoff")
                throw TestFailure.ambiguous
            }
            Issue.record("Expected handoff failure")
        } catch {
            #expect(error as? TestFailure == .ambiguous)
        }

        let values = events.values
        #expect(values == ["handoff"])
        #expect(!values.contains("stop"))
        #expect(!values.contains("start"))
        #expect(!values.contains("release-system-proxy"))
    }

    @Test("Candidate termination is retained until the handoff owner handles it")
    func candidateTerminationIsDeferred() {
        let old = UUID()
        let candidate = UUID()
        var transition = ReloadTransition(
            oldSession: old,
            candidateSession: candidate
        )

        transition.recordTermination(session: candidate, statusCode: 17)

        #expect(transition.terminationStatus(for: candidate) == 17)
        #expect(transition.terminationStatus(for: old) == nil)
    }
}

private actor PreflightCancellationGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let pending = pauseWaiters
        pauseWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private enum TestFailure: Error {
    case preflight
    case ambiguous
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
