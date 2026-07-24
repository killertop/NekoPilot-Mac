import Foundation

/// The destructive boundaries of a live reload, kept small and testable.
///
/// This pipeline cannot accept stop, start, or system-proxy release
/// operations. Candidate failure therefore cannot advance to promotion or
/// handoff; the live process and its proxy ownership remain untouched.
enum ReloadSafetyPipeline {
    static func prepare(
        preflight: () async throws -> Void,
        commit: () throws -> Void
    ) async throws {
        try await preflight()
        try Task.checkCancellation()
        try commit()
    }

    static func handoff(_ action: () async throws -> Void) async throws {
        try await action()
    }
}
