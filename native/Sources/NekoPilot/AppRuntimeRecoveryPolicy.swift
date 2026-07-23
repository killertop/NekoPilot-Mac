import Foundation
import NekoPilotCore

/// Small, deterministic recovery decisions shared by AppModel transactions.
///
/// Keeping these rules free of UI and process side effects makes the boundary
/// between safe cancellation and a required core restart explicit.
enum AppRuntimeRecoveryPolicy {
    static func keepsPersistedRules(after error: Error, didPersist: Bool) -> Bool {
        guard didPersist else { return false }
        if error is CancellationError { return true }
        return (error as? EngineFailure)?.kind == .reloadCommitted
    }

}
