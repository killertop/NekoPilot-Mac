import Foundation

/// The destructive boundaries of a live reload, kept small and testable.
///
/// This pipeline cannot accept stop, start, or system-proxy operations.
/// Candidate failure therefore cannot advance to commit or SIGHUP, and an
/// ambiguous post-SIGHUP confirmation can only be reported while the live
/// process and its proxy ownership remain untouched.
enum ReloadSafetyPipeline {
    static func prepare(
        preflight: () async throws -> Void,
        commit: () throws -> Void
    ) async throws {
        try await preflight()
        try Task.checkCancellation()
        try commit()
    }

    static func signal(_ action: () throws -> Void) throws {
        try action()
    }

    static func confirm(_ action: () async throws -> Void) async throws {
        try await action()
    }
}
