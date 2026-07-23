import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Non-destructive live reload pipeline")
struct ReloadSafetyPipelineTests {
    @Test("Failed candidate health stops before commit and signal")
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

    @Test("Ambiguous confirmation has no stop start or proxy release stage")
    func ambiguousConfirmationPreservesLiveRuntime() async {
        let events = EventRecorder()

        do {
            try ReloadSafetyPipeline.signal {
                events.append("sighup")
            }
            try await ReloadSafetyPipeline.confirm {
                events.append("confirm")
                throw TestFailure.ambiguous
            }
            Issue.record("Expected ambiguous confirmation")
        } catch {
            #expect(error as? TestFailure == .ambiguous)
        }

        let values = events.values
        #expect(values == ["sighup", "confirm"])
        #expect(!values.contains("stop"))
        #expect(!values.contains("start"))
        #expect(!values.contains("release-system-proxy"))
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
