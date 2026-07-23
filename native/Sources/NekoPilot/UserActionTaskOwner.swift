import Foundation

/// Owns business operations initiated by transient SwiftUI views.
///
/// The views do not retain task handles, so the application model uses this
/// registry to cancel and join all outstanding mutations during termination.
@MainActor
final class UserActionTaskOwner {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    var activeCount: Int { tasks.count }

    func submit(_ operation: @escaping @MainActor () async -> Void) {
        let identifier = UUID()
        tasks[identifier] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[identifier] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    func cancelAndWait() async {
        let active = Array(tasks.values)
        active.forEach { $0.cancel() }
        tasks.removeAll()
        for task in active {
            await task.value
        }
    }
}
