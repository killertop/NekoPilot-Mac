import Foundation
import NekoPilotCore

/// Small, deterministic recovery decisions shared by AppModel transactions.
///
/// Keeping these rules free of UI and process side effects makes the boundary
/// between safe cancellation and a required core restart explicit.
enum AppRuntimeRecoveryPolicy {
    static func keepsPersistedRules(after error: Error, didPersist: Bool) -> Bool {
        didPersist && error is CancellationError
    }

}
