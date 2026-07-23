import Foundation

/// Runs the post-import side effects after the importer has committed data.
///
/// Keeping the cancellation checkpoints in one small workflow prevents a
/// superseded deep link from refreshing, reloading, or selecting after a newer
/// request takes ownership.
@MainActor
enum ImportedNodePostprocessor {
    static func run<Node>(
        refresh: () async -> Void,
        resolveNode: () -> Node?,
        isEngineRunning: () async -> Bool,
        reload: (Node) async throws -> Void,
        select: (Node) async -> Void,
        isShuttingDown: () -> Bool
    ) async throws {
        try checkCancellation(isShuttingDown: isShuttingDown)
        await refresh()
        try checkCancellation(isShuttingDown: isShuttingDown)
        guard let node = resolveNode() else { return }
        if await isEngineRunning() {
            try checkCancellation(isShuttingDown: isShuttingDown)
            try await reload(node)
        }
        try checkCancellation(isShuttingDown: isShuttingDown)
        await select(node)
        try checkCancellation(isShuttingDown: isShuttingDown)
    }

    private static func checkCancellation(
        isShuttingDown: () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard !isShuttingDown() else { throw CancellationError() }
    }
}
